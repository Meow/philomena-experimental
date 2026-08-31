# UserNameChanges SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 7 UserNameChanges-owned, moved, delegated, preload, export, and worker-related sites

## Changed shapes

### User rename-history listing

- Master: `lib/philomena_web/controllers/profile_controller.ex:277-287`
  (`set_name_changes/2`) queried `user_name_changes` with
  `user_id = $user_id`, ordered by `id DESC`, and returned every matching row
  with `Repo.all`. Authorization was checked before the query by the
  controller plug.
- context-logic: `lib/philomena/user_name_changes.ex:19-23,63-68`
  (`history_query/1`, `load_history/3`) retains `user_id = $user_id` and
  `ORDER BY id DESC`, then calls `Repo.paginate(pagination)`. The page query
  adds `LIMIT/OFFSET`; Scrivener also issues a `count(*)` query over the same
  user predicate. `Profiles.load_name_changes/2` calls it with page 1 and
  page size 250 (`lib/philomena/profiles.ex:314-332`).
- Delta: the unbounded collection became a user-scoped paginated collection
  with a count query. The filter and ordering columns are unchanged; the new
  limit/offset access path makes the existing ordering relevant to page
  retrieval. The old controller-level authorization became context/profile
  authorization, which is a boundary/correctness change rather than an index
  predicate change.
- Index status: no index action; ordering extension rejected by focused review
- Evidence: `index_user_name_changes_on_user_id` exists in
  `priv/repo/structure.sql:4458-4461` and covers the equality predicate and
  count query. A possible covering candidate would be
  `(user_id, id DESC)`, but the focused review rejects it because name changes
  are infrequent and per-user history is tightly bounded; the
  history listing is capped at 250 rows per profile. The current single-column
  index is sufficient evidence for the changed filter; do not add a composite
  index without production-like history cardinality and workload evidence.
- Confidence: high

## Unchanged or non-index-relevant sites

- Rename-history insert moved from the Users-owned inline transaction in
  `master:lib/philomena/users.ex:851-852` to
  `context-logic:lib/philomena/user_name_changes.ex:25-44`
  (`record_rename/3`). Both construct an insert into `user_name_changes` with
  the trusted `user_id` and prior `name`; the surrounding transaction changed
  from direct `Repo.transaction`/`Ecto.Multi` to the context's
  `Philomena.Multi` composition and adds a locked user lookup, but the insert
  has no row-selection predicate and needs no index. The current caller is
  `Philomena.Users.update_name/2` at `lib/philomena/users.ex:1745-1763`.
- User search-index preload remains unchanged between refs. The master
  `Users.indexing_preloads/0` and current
  `lib/philomena/users.ex:2839-2849` use a `has_many :name_changes`
  association with a select query projecting only `name`. The association
  preload issues `user_name_changes.user_id IN (...)`; the existing
  `index_user_name_changes_on_user_id` covers that lookup. No association
  `where` or `order_by` is defined in `User` (`lib/philomena/users/user.ex:43`),
  so the nested preload does not add a changed ordering shape.
- User reindexing remains a worker/background workload rather than a new
  UserNameChanges query. `Users.perform_reindex/2` preloads `name_changes`
  before serializing the user search document; `UserRenameWorker` updates
  OpenSearch references and does not query `user_name_changes` directly.
  OpenSearch bodies and mappings are outside this audit.
- Data export continues to include `{UserNameChange, [:name]}` in
  `lib/philomena/data_exports/aggregator.ex:75-81`. Its generic
  `select_schema_by_key/5` at `:166-181` filters by `user_id`, selects
  `created_at` and `name`, and streams ID batches. The source shape is
  unchanged; the existing user-id index supports the initial filter, while
  the batch helper's primary-key ordering/`id > $last_id` continuation is an
  unchanged generic access pattern.
- The `UserNameChange` schema at
  `lib/philomena/user_name_changes/user_name_change.ex:9-18` has only a plain
  `belongs_to :user` association and no association filter/order. Its added
  type declaration does not affect SQL.
- Profile rendering and controller assignment moved from the old
  `set_name_changes/2` plug to `Profiles.load_name_changes/2` and
  `ProfileController.put_name_changes/3` (`lib/philomena_web/controllers/profile_controller.ex:87-92`).
  This is query ownership/caller movement; the retained history operation is
  covered above.

## New, deleted, moved, or ambiguous sites

- The current `load_history/3` is a new context API paired with the old
  profile-controller workload, not a new independent workload. It adds an
  explicit `:index` authorization check and is called only after Profiles'
  `:show_details` check. Review the authorization layering separately from
  SQL/index concerns.
- Master-only generated CRUD APIs in
  `lib/philomena/user_name_changes.ex` (`list_user_name_changes/0`,
  `get_user_name_change!/1`, `create_user_name_change/1`,
  `update_user_name_change/2`, `delete_user_name_change/1`, and
  `change_user_name_change/1`) were removed. Repository-wide production
  caller search found no uses of these APIs. The former list was an
  unfiltered table scan, the getter was a primary-key lookup, and the update/
  delete helpers operated on already-loaded primary-key structs; their removal
  creates no missing index recommendation.
- No UserNameChanges-owned worker, maintenance `Repo.delete_all`/
  `update_all`, locking query, or additional nested schema query was found in
  either ref. Rename side effects are indexing jobs and therefore outside
  PostgreSQL query-shape scope.

## Follow-ups

- If profile histories become large or the endpoint is high frequency, measure
  the paginated page query with representative data. A candidate
  `user_name_changes (user_id, id DESC)` would support the equality filter and
  newest-first pagination, but it carries additional write/storage cost and is
  not recommended from the current evidence.
- Confirm in the shared/Users audit that the `Users` indexing preload and rename
  transaction are assigned one canonical cross-context finding; this report
  records the UserNameChanges side only.
- The new bounded profile result and authorization gates are behavioral
  changes worth retaining in correctness review; they are not index actions.

## Index and migration evidence

- Current `priv/repo/structure.sql` defines the `user_name_changes` primary key
  on `id`, ordinary B-tree `index_user_name_changes_on_user_id` on `user_id`,
  and a foreign key from `user_name_changes.user_id` to `users.id`.
- The relevant table and index definitions are unchanged between `master` and
  `context-logic`. Git history traces both to the initial structure dump
  (`80c8b744`, `add structure file`); no migration between the refs adds,
  removes, or changes a UserNameChanges index. The later
  `20200617113333_prod_schema_sync2.exs` only changes the sequence type for
  `user_name_changes_id_seq`.
- No index candidate is raised. The focused review notes names can change only
  once per 90 days (at most about 40 changes per user over a decade), so the
  existing foreign-key index plus bounded history page makes an ordering
  extension unjustified.
