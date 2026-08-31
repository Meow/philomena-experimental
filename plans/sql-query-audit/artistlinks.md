# ArtistLinks SQL shape audit

Refs: master -> context-logic  
Status: complete

--- files ---

plans/sql-query-shape-audit.md  
lib/philomena/artist_links.ex  
lib/philomena/artist_links/artist_link.ex  
lib/philomena/artist_links/automatic_verifier.ex  
lib/philomena/artist_links/query_form.ex  
lib/philomena/artist_links/query_builder.ex  
lib/philomena/users/user.ex  
lib/philomena/tags/tag.ex  
lib/philomena/tags.ex  
lib/philomena_web/controllers/profile/artist_link_controller.ex  
lib/philomena_web/controllers/admin/artist_link_controller.ex  
lib/philomena_web/controllers/admin/artist_link/verification_controller.ex  
lib/philomena_web/controllers/admin/artist_link/contact_controller.ex  
lib/philomena_web/controllers/admin/artist_link/reject_controller.ex  
lib/philomena_web/plugs/admin_counters_plug.ex  
lib/philomena/release.ex  
lib/philomena_web/views/api/json/profile_view.ex  
lib/philomena_web/templates/admin/artist_link/index.html.slime  
deps/canary/lib/canary/plugs.ex  
priv/repo/structure.sql  
priv/repo/migrations/20201124224116_rename_user_links_table.exs  
priv/repo/migrations/20240818182358_cleanup.exs

Query sites inspected: 15

## Changed shapes

### Profile tag resolution used by `create_artist_link/3` and `update_artist_link/4`

- Master: `Philomena.Tags.get_tag_or_alias_by_name/1` (called from the old
  ArtistLinks context) issued `tags WHERE name = $1`, with an `aliased_tag`
  preload. The lookup was one equality query followed by the association
  preload.
- context-logic: `lib/philomena/artist_links.ex:206-211` and `:310-315` compose
  `Tags.put_canonicalize_tag_name_sets/2`. Its shared Multi query is
  `tags WHERE name IN (...)`, preloading `implied_tags` and
  `aliased_tag.implied_tags`, followed by a `tags WHERE id IN (...) ORDER BY id
FOR UPDATE` lock query. With no supplied tag name, the `IN` list is empty and
  the shared query returns no tag.
- Delta: the old single-name equality/alias lookup moved into the shared tag
  canonicalization helper, which changes `=` to `IN`, adds implication
  preloads, and adds deterministic row locking. This is a shared Tags query;
  the ArtistLinks report records the consumer and the shared report should own
  the canonical finding.
- Index status: covered; no index action.
- Evidence: `priv/repo/structure.sql:4297-4301` has the unique B-tree
  `index_tags_on_name`, covering both equality and `IN` name lookups. The lock
  query uses tag primary keys; no ArtistLinks or tag index change is present in
  either ref. The extra preload queries use foreign-key/primary-key lookups.
- Confidence: high

### Profile-user lookup used by `list_artist_links/2`, `new_artist_link/2`, `create_artist_link/3`, `show_artist_link/3`, `edit_artist_link/3`, and `update_artist_link/4`

- Master: `lib/philomena_web/controllers/profile/artist_link_controller.ex` (old resource loader before each profile operation) selected a `users` row by `slug`; the old loader/authorization path supplied the request authorization. The old artist-link index then queried `artist_links WHERE user_id = $1`.
- context-logic: `lib/philomena/artist_links.ex:31-35`, `load_authorized_profile/3` builds `users WHERE slug = $1 AND deleted_at IS NULL`, then calls `Loader.one_and_authorize/3`.
- Delta: added the fixed `deleted_at IS NULL` predicate to the profile-user lookup; the query moved into the context and is shared by six public operations. The `slug` lookup remains the member lookup key. This is an index-relevant filter delta only if the users lookup is not already covered by the slug index and the deleted-row proportion is material.
- Index status: covered for the lookup key; no index action.
- Evidence: `priv/repo/structure.sql:4542-4545` (same definition at both refs)
  has the unique B-tree `index_users_on_slug`, covering the member lookup; no
  ArtistLinks migration or structure change adds a new index. `deleted_at` is
  an additional visibility predicate, not evidence for a standalone index.
- Confidence: high

### Scoped artist-link member lookup for profile show/edit/update

- Master: `lib/philomena_web/controllers/profile/artist_link_controller.ex` (old `load_and_authorize_resource` for `show`, `edit`, and `update`) loaded `artist_links` by primary key, with `[:user, :tag, :contacted_by_user]` preloaded; the profile user was loaded separately by slug.
- context-logic: `lib/philomena/artist_links.ex:38-44`, `load_scoped_artist_link/4`, builds `artist_links WHERE user_id = $1 AND id = $2`, preloads the same associations, and passes the relation to `Loader.fetch_and_authorize/4`.
- Delta: added the parent `user_id` predicate to the primary-key lookup. The three operations share this shape; the preload set is unchanged. The primary-key equality remains the selective lookup key, so the additional equality does not require a new index.
- Index status: covered; no index action.
- Evidence: `priv/repo/structure.sql:2758-2762` has `artist_links_pkey (id)` and `:3485-3488` has `index_artist_links_on_user_id`. The primary key covers the member lookup; the single-column user index covers the collection lookup below.
- Confidence: high

### Profile artist-link collection (`list_artist_links/2`)

- Master: `lib/philomena_web/controllers/profile/artist_link_controller.ex`, old `index/2`, queried `artist_links WHERE user_id = $1` with `Repo.all/1` and no ordering or visibility predicate.
- context-logic: `lib/philomena/artist_links.ex:81-86`, `list_artist_links/2`, queries the same `artist_links WHERE user_id = $1` after the new profile-user lookup.
- Delta: module/API movement only; relational shape is unchanged.
- Index status: covered; no index action.
- Evidence: `priv/repo/structure.sql:3485-3488` contains `index_artist_links_on_user_id`. The query has no `ORDER BY`, pagination, join, or association `where` modifier.
- Confidence: high

### Admin artist-link pending collection (`list_admin_artist_links/3`, default state branch)

- Master: `lib/philomena_web/controllers/admin/artist_link_controller.ex`, old `index/2` default branch, queried `artist_links WHERE aasm_state IN ('unverified', 'link_verified', 'contacted') ORDER BY created_at DESC`, then paginated and preloaded `tag`, verifier/contact users, and `user.linked_tags`/`user.awards.badge`.
- context-logic: `lib/philomena/artist_links/query_builder.ex:22-31`, `build_query/1` with default `QueryForm.states`, produces `artist_links WHERE aasm_state IN (...) ORDER BY created_at DESC, id DESC`; `lib/philomena/artist_links.ex:114-124` applies the same preloads and `Repo.paginate/2`.
- Delta: added deterministic `id DESC` tie-breaker to the ordering; query
  construction moved into a form/builder. The default state set is the same as
  master, and pagination/count behavior is unchanged.
- Index status: reviewed and rejected (human production review).
- Evidence: `priv/repo/structure.sql:3450-3453` covers `aasm_state`, but
  there is no `created_at` ordering index. A representative local
  `EXPLAIN (FORMAT JSON)` used the state index via a Bitmap Index Scan and
  then a Sort on `(created_at DESC, id DESC)`. This confirms the missing
  ordering path for that sample, but it was not `ANALYZE`d and does not justify
  a migration without production cardinality/selectivity evidence. A possible
  workload-specific candidate is `artist_links (aasm_state, created_at DESC,
id DESC)`; the current single-column state index may still be adequate.
- Confidence: high for the shape delta; no index candidate after production review

### Admin artist-link all-state collection (`list_admin_artist_links/3`, explicit states branch)

- Master: `lib/philomena_web/controllers/admin/artist_link_controller.ex`, old `index/2` `%{"all" => _value}` branch, queried all `artist_links`, ordered by `created_at DESC`, then paginated with the admin preloads.
- context-logic: `lib/philomena/artist_links/query_builder.ex:35-36`, an empty `states` list emits no state predicate and orders by `created_at DESC, id DESC`; `lib/philomena/artist_links.ex:114-124` paginates and preloads.
- Delta: the old `all` request branch is replaced by an explicit empty/all-state `states` form branch; ordering gains `id DESC`. The all-state page has no filtering predicate.
- Index status: reviewed and rejected (human production review).
- Evidence: no current `created_at`/`id` ordering index is present in
  `priv/repo/structure.sql`; the primary key only covers `id`, not the leading
  `created_at`. The same representative planning check shows the need to sort
  after filtering for the pending branch; no production plan or workload
  evidence supports the added write/storage cost of `(created_at DESC, id
DESC)`.
- Confidence: high for the shape delta; no index candidate after production review

### Admin artist-link filtered-state branches (`list_admin_artist_links/3`)

- Master: the default branch had the fixed pending-state predicate, while the
  old text and `all` branches did not accept an arbitrary state list.
- context-logic: `lib/philomena/artist_links/query_builder.ex:35-41` emits
  `artist_links WHERE aasm_state IN ($states)` for every non-empty submitted
  state list, including verified-only, rejected-only, or any multi-state
  selection, with `ORDER BY created_at DESC, id DESC`.
- Delta: verified/rejected and arbitrary state selections are new query
  branches; the default pending branch is the paired old shape. The current
  text branch also combines this state predicate with the user/URI text OR,
  whereas the master text branch searched every state.
- Index status: existing state index covers the filter; ordering composites
  reviewed and rejected for this workload.
- Evidence: `priv/repo/structure.sql:3450-3453` has
  `index_artist_links_on_aasm_state`. No index has `created_at` as a leading
  key, and no representative plan or workload/cardinality data is available.
- Confidence: high for the branch delta; no index recommendation after review

### Admin artist-link text search (`list_admin_artist_links/3`, text branch)

- Master: `lib/philomena_web/controllers/admin/artist_link_controller.ex`, old `index/2` `%{"lq" => query}` branch, joined `users` through `artist_links.user_id` and filtered `ILIKE(users.name, '%term%') OR ILIKE(artist_links.uri, '%term%')`, then ordered by `created_at DESC` and paginated with the admin preloads.
- context-logic: `lib/philomena/artist_links/query_builder.ex:44-52`,
  `maybe_filter_text/2`, emits the same inner association join and same
  leading-wildcard OR predicate, then orders by `created_at DESC, id DESC`;
  `lib/philomena/artist_links.ex:114-124` applies the same preloads and
  `Repo.paginate/2`. The default form state also adds
  `aasm_state IN ('unverified', 'link_verified', 'contacted')` unless the
  request supplies another state list.
- Delta: query builder/form movement plus the `id DESC` tie-breaker; the join
  and text predicates are unchanged, but the ordinary text branch now has the
  pending-state predicate that the master text branch lacked. This is both an
  index-relevant filter delta and a behavior/visibility change.
- Index status: no index action.
- Evidence: ordinary B-tree indexes do not solve leading-wildcard `ILIKE`, and the OR spans two tables. A trigram/specialized search design would require separate workload and extension evidence; none was produced here. The existing `artist_links.user_id` index supports the join direction, and users primary/unique key coverage supports the referenced user rows.
- Confidence: high

### Invalid admin-query fallback (`list_admin_artist_links/3`)

- Master: no counterpart; the old controller did not have a changeset-invalid branch.
- context-logic: `lib/philomena/artist_links.ex:128-129` paginates `where(ArtistLink, false)` after `QueryBuilder.build_query/1` returns an error. `Repo.paginate/2` issues an always-empty page/count workload.
- Delta: new/unpaired defensive query; no user-controlled rows are selected.
- Index status: no index action.
- Evidence: the constant-false predicate is not an index candidate.
- Confidence: high

### Tag-alias artist-link conflict deletion (`put_alias_tag/3`)

- Master: `lib/philomena/tags.ex:453-455` directly issued the paired
  `UPDATE artist_links SET tag_id = $target_tag_id WHERE tag_id =
$source_tag_id`. It did not delete conflicting artist links first.
- context-logic: `lib/philomena/artist_links.ex:487-504`, called from
  `lib/philomena/tags.ex:1118`, builds a conflict relation over
  `artist_links source JOIN artist_links target ON target.tag_id =
$target_tag_id AND target.uri = source.uri AND target.user_id =
source.user_id`, with both source and target `aasm_state != 'rejected'`,
  selects source IDs, and deletes rows whose `id IN (subquery(conflicts))`.
  The following update has the same `WHERE tag_id = $source_tag_id` shape as
  master.
- Delta: the retarget update is moved into the ArtistLinks-owned Multi but is
  relationally unchanged; the conflict self-join, rejected-state predicates,
  and subquery-driven delete are genuinely new. The conflict delete is a
  correctness/data-integrity behavior change, not merely an index concern.
- Index status: covered; no index action.
- Evidence: `priv/repo/structure.sql:3471-3474` has
  `index_artist_links_on_tag_id`, covering source selection and the retarget
  update; the primary key at `:2758-2762` covers delete-by-id. The partial
  unique index at `:3478-3482` is `(uri, tag_id, user_id) WHERE aasm_state <>
'rejected'`; the target join supplies equality for all three key columns and
  the matching partial predicate, so its non-leading `tag_id` position is not
  by itself a missing access path. A representative local `EXPLAIN (FORMAT
JSON)` used that partial index for both source and target tag filters, then
  applied the URI/user join filter; the small, unanalyzed dev dataset caused
  target materialization, so this is not production evidence for another
  index. No additional index is justified.
- Confidence: high

## Unchanged or non-index-relevant sites

- `lib/philomena/artist_links/automatic_verifier.ex:34-40`, `links_to_check/1`: unchanged `artist_links WHERE aasm_state = 'unverified' AND next_check_at < $now`, used by `generate_updates/0` and `run_automatic_verification!/0`. Existing `index_artist_links_on_aasm_state` and `index_artist_links_on_next_check_at` cover the two lookup columns. No SQL shape changes found for the automatic verifier itself.
- `lib/philomena/artist_links.ex:524-529`, `count_artist_links/1`: unchanged aggregate `COUNT(*)` over `aasm_state IN ('unverified', 'link_verified')`; only the authorization API moved from `Canada.Can.can?/3` to `authorize/3`. Existing `index_artist_links_on_aasm_state` covers the filter; no index action.
- `lib/philomena/artist_links/artist_link.ex:10-25`: schema field and association declarations do not issue SQL alone. The added virtual `tag_name` field and state helper functions do not alter database query shape.
- `lib/philomena/users/user.ex:31-36`: `links`, `verified_links WHERE aasm_state = 'verified'`, `public_links WHERE public = true AND aasm_state = 'verified'`, and `linked_tags` through `verified_links` are unchanged between refs. These association `where` clauses affect ArtistLinks preloads and API profile rendering; they are not new in context-logic.
- `lib/philomena/tags/tag.ex:80-82`: `verified_links`, `public_links`, and `hidden_links` association predicates are unchanged. They are relevant to tag/profile preloads but have no changed ArtistLinks SQL shape.
- `lib/philomena_web/views/api/json/profile_view.ex:21-26`: consumes preloaded `user.public_links`; no query definition or preload change in this ref pair.
- `lib/philomena_web/plugs/admin_counters_plug.ex:38`: still invokes `ArtistLinks.count_artist_links/1`; the other counter API moves do not change the ArtistLinks aggregate.
- `lib/philomena/release.ex:52-54`: invokes the renamed automatic-verification context API; no query change.
- `lib/philomena_web/controllers/admin/artist_link/{verification,contact,reject}_controller.ex`: old controller-side primary-key load/preload is moved into `load_artist_link/3` and the context operations. The update predicates remain changeset-by-primary-key operations; moderation-log and badge steps add no ArtistLinks row-selection predicate.
- `lib/philomena/badges.ex:533-543` replaces the deleted
  `ArtistLinks.BadgeAwarder` callback. Its badge-title equality lookup and
  badge/user award existence lookup are the same relational shapes as master,
  only executed inside the current verification Multi; badge indexes are
  shared/Badges-owned.
- Existing ArtistLinks indexes are unchanged at both refs: primary key `(id)`; B-tree indexes on `(aasm_state)`, `(next_check_at)`, `(tag_id)`, `(user_id)`, `(verified_by_user_id)`, `(contacted_by_user_id)`; and the partial unique `(uri, tag_id, user_id) WHERE aasm_state <> 'rejected'`. The relevant migration history is the table/index rename in `20201124224116_rename_user_links_table.exs`; `20240818182358_cleanup.exs` only removes unused columns. The branch does change `structure.sql` and adds unrelated commission/image-intensity migrations, but no ArtistLinks table/index definition changes.

## New, deleted, moved, or ambiguous sites

- `lib/philomena/artist_links/badge_awarder.ex` is deleted and its badge lookup/award callback is replaced by `Badges.put_award_artist_badge/3` in the verification `Multi`. The ArtistLinks row lookup remains the same primary-key member lookup; badge-table queries are shared/Badges-owned and are not duplicated here.
- The old profile/admin controller query sites are moved into `Philomena.ArtistLinks`, `QueryBuilder`, and `Loader` calls. They are paired above rather than counted as independent new workloads.
- `put_alias_tag/3` is the ArtistLinks owner for the moved alias update and its
  new conflict-delete workload. Its caller is the tag alias transaction, so
  the canonical cross-context finding should be linked from the Tags
  report/shared synthesis.
- The admin `all` URL contract changed from the old `?all=true` branch to explicit `lq[states][]` values in `lib/philomena_web/templates/admin/artist_link/index.html.slime:20-23`. The current controller passes only `params["lq"]` to the builder. If legacy `?all=true` links or clients remain, they now fall through to the default pending-state query; this is a correctness/behavior concern, not an index recommendation.
- `load_scoped_artist_link/4` calls `load_authorized_profile(actor, :show, slug)` even when the requested artist-link action is `:edit` or `:update`. This is an authorization semantics concern separate from SQL access-path analysis.

## Follow-ups

- No application code, migration, schema, or test was changed by this audit.
- The default/all/filtered admin order changes are index-relevant because they
  add a stable tie-breaker and paginate by `created_at`, but the focused review
  rejects both ordering composites because bitmap filtering plus a re-sort is
  marginally better for multi-state requests; OpenSearch remains the preferred
  path for high-volume search.
- The alias conflict query is already covered by the source tag index, primary
  key, and the existing partial unique target index. The local plan uses the
  partial index but materializes the small target side; production cardinality
  and alias frequency would be needed before considering any additional index.
- Verify whether `?all=true` is still an externally used admin URL and whether the `:show` profile authorization action is intentional for edit/update. These are correctness questions, not index findings.
