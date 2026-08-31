# ModerationLogs SQL shape audit

Refs: master -> context-logic
Status: complete

--- status ---

Audited the ModerationLogs context, its schema and path helpers, the moderation-log controller and deleted Canary plug, the retention release task, authorization wiring, moved logging callers, and the moderation-log tests. No SQL shape changes were found in the insert or cleanup workloads; the listing order changed as described below.

--- relevant files ---

lib/philomena/moderation_logs.ex
lib/philomena/moderation_logs/moderation_log.ex
lib/philomena/moderation_logs/paths.ex
lib/philomena/release.ex
lib/philomena/users/ability.ex
lib/philomena_web.ex
lib/philomena_web/controllers/moderation_log_controller.ex
lib/philomena_web/plugs/moderation_log_plug.ex
lib/philomena_web/views/layout_view.ex
lib/philomena/{adverts,artist_links,badges,bans,comments,conversations,dnp_entries,duplicate_reports,images,mod_notes,posts,reports,tag_changes,tags,topics,users}.ex (moved log callers)
priv/repo/migrations/20211107130226_create_moderation_logs.exs
priv/repo/migrations/20240818182358_cleanup.exs
priv/repo/structure.sql
test/philomena/moderation_logs_test.exs
test/philomena/moderation_logs/paths_test.exs
test/philomena_web/controllers/moderation_log_controller_test.exs

Query sites inspected: 10

## Changed shapes

### Retained moderation-log index page (`list_moderation_logs`)

- Master: `lib/philomena/moderation_logs.ex:20-26`, `list_moderation_logs/1`; base table `moderation_logs`, all schema columns selected; fixed predicate `created_at >= cutoff`; no joins; `ORDER BY created_at DESC`; Scrivener count query with the same predicate and page query with `LIMIT/OFFSET`; `preload(:user)` issues a separate `users` primary-key `IN` lookup for the page's `user_id` values.
- context-logic: `lib/philomena/moderation_logs.ex:24-30`, private `list_moderation_logs/1`, called by the authorized public `list_moderation_logs/2` at lines 49-52; the same base table, selection, predicate, count/page pagination, and user preload, with `ORDER BY created_at DESC, id DESC`.
- Delta: an `id DESC` tie-breaker was added to the history ordering. The actor is used only by `authorize/3`; there is no actor filter, target filter, join, visibility predicate, grouping, distinct, or lock clause in either ref.
- Index status: reviewed and rejected (human production review).
- Evidence: `moderation_logs_created_at_index` on `(created_at)` exists in both `priv/repo/structure.sql` files and is used by the two-week range and the leading ordering key. A read-only `EXPLAIN (FORMAT JSON)` on the representative page query (`created_at >= now() - interval '2 weeks'`, `ORDER BY created_at DESC, id DESC`, `LIMIT 25 OFFSET 0`) used that index and an `Incremental Sort` with `Presorted Key: created_at`; the count query used the same index in a bitmap scan. This confirms a plausible residual-sort access cost. The `(type, created_at)` and `(user_id, created_at)` indexes cannot lead this query because neither leading column is filtered. The exact order could use `CREATE INDEX moderation_logs_created_at_id_index ON moderation_logs (created_at DESC, id DESC)`, but the local plan estimated only 183 retained rows; the focused review reports a table under 10,000 rows, biweekly cleanup, and no request timeouts, so avoiding the residual sort is not worth another write-maintained index. The `users(id)` primary key covers the preload lookup.
- Confidence: medium

### Moderation-log inserts (`create_moderation_log`, `put_log`)

- Master: `lib/philomena/moderation_logs.ex:45-50`, `create_moderation_log/4`; inserts one `moderation_logs` row with `user_id`, `type`, `subject_path`, `body`, and `created_at` through the changeset. The deleted `PhilomenaWeb.ModerationLogPlug` at `lib/philomena_web/plugs/moderation_log_plug.ex:30-38` called this same insert after the owning controller action.
- context-logic: `lib/philomena/moderation_logs.ex:78-81`, `put_log/6`, emits the same insert through `Multi.insert`; `lib/philomena/moderation_logs.ex:105-113`, callback `put_log/4`, emits the same insert through `repo.insert`; `lib/philomena/moderation_logs.ex:129-139`, `create_moderation_log/4`, retains the direct insert API for actor or user input. The moved callers are the domain context functions in `adverts.ex`, `artist_links.ex`, `badges.ex`, `bans.ex`, `comments.ex`, `conversations.ex`, `dnp_entries.ex`, `duplicate_reports.ex`, `images.ex`, `mod_notes.ex`, `posts.ex`, `reports.ex`, `tag_changes.ex`, `tags.ex`, `topics.ex`, and `users.ex`.
- Delta: logging moved into the owning transaction and callback-derived values were added; the insert target and conflict/row-selection predicates are unchanged. `foreign_key_constraint(:user_id)` adds changeset handling for the existing FK, not a new query shape.
- Index status: no index action.
- Evidence: inserts have no lookup predicate or upsert conflict target. Existing `moderation_logs_user_id_index` supports the `user_id` foreign-key cascade path; the primary key and existing indexes are unchanged between refs.
- Confidence: high

### Retention cleanup (`cleanup!/0`)

- Master: `lib/philomena/moderation_logs.ex:61-64`, `cleanup!/0`; `DELETE FROM moderation_logs WHERE created_at < cutoff`.
- context-logic: `lib/philomena/moderation_logs.ex:153-156`, `cleanup!/0`; the same delete predicate and affected table, still called by `Philomena.Release.clean_moderation_logs/0`.
- Delta: documentation/specification and release wiring only; the write-row selection predicate is unchanged.
- Index status: covered.
- Evidence: `moderation_logs_created_at_index` exists in both structure dumps and directly supports the retention range. The initial migration `priv/repo/migrations/20211107130226_create_moderation_logs.exs:14-18` created this index, and no later migration changes its definition. No new partial or specialized index is justified.
- Confidence: high

## Unchanged or non-index-relevant sites

- `lib/philomena/moderation_logs.ex:19-22`, `log_changeset/4`: centralizes construction of the same `moderation_logs` insert changeset; it does not add a database selection predicate.
- `lib/philomena/moderation_logs/moderation_log.ex:9-16`, schema: `belongs_to :user` remains an unscoped association. The added type declaration and `foreign_key_constraint(:user_id)` do not alter SQL. The association preload remains a `users.id IN (...)` lookup with no association `where` or `order_by` clause.
- `lib/philomena/moderation_logs/paths.ex:1-129`: path serialization, including the new report path helper, stores opaque strings and issues no SQL.
- `lib/philomena/users/ability.ex:270-271` and `lib/philomena/authorization.ex:55-61`: moderation-log authorization is an in-memory Canada check; it does not add actor or target predicates to the listing query.
- `lib/philomena_web/controllers/moderation_log_controller.ex:8-12`: controller relocation and `action_fallback` do not alter the context's final list query.
- All moved `ModerationLogs.put_log`/`create_moderation_log` callers listed above preserve the same moderation-log insert row shape. Their surrounding subject lookups, locks, updates, deletes, and preloads remain owned by their respective contexts and are not ModerationLogs queries.
- The current and master `priv/repo/structure.sql` definitions for `moderation_logs` are the same: `id` primary key, `user_id` FK with `ON DELETE CASCADE`, and ordinary B-tree indexes on `(created_at)`, `(type)`, `(type, created_at)`, `(user_id)`, and `(user_id, created_at)`.

## New, deleted, moved, or ambiguous sites

- The master `load_and_authorize_resource` plug on `lib/philomena_web/controllers/moderation_log_controller.ex:7-9` performed an additional index-action collection load through Canary's `fetch_all`: an unordered, unfiltered `SELECT moderation_logs.*`, followed by a `users` preload query. The controller did not consume that assigned collection; it then ran `ModerationLogs.list_moderation_logs/1`. The plug and its import in `lib/philomena_web.ex` were deleted in context-logic, so this redundant full-table workload has no current counterpart. It is a deleted workload, not a missing index candidate.
- The old `PhilomenaWeb.ModerationLogPlug` was called by many master controllers and has no current counterpart. Its only ModerationLogs SQL was the insert already paired under “Moderation-log inserts”; the current domain callers use `Multi` composition or the retained direct API. No caller introduced an actor/target lookup against `moderation_logs`.
- No ambiguous ModerationLogs query sites were found in workers or maintenance code. `Philomena.Release.clean_moderation_logs/0` is the sole production cleanup caller.
- Test-only direct `Repo.one`, `Repo.aggregate`, and `Repo.delete_all` calls against `ModerationLog` are fixtures/assertions and are not production workloads; they do not define a changed application query shape.

## Follow-ups

- The `id DESC` addition is a deterministic-pagination correctness improvement
  for equal `created_at` values, not evidence that a new index is worthwhile.
  The focused review rejects `(created_at DESC, id DESC)` given the small,
  infrequently audited table and biweekly cleanup.
- “Actor-scoped” in the current module documentation means authorization-scoped. The SQL still lists all retained logs for an authorized moderator/admin; it does not filter by `moderation_logs.user_id` (actor) or `subject_path` (target). This is unchanged between refs and therefore no actor/target index is proposed.
- No SQL shape changes found in `Paths`, the moderation-log schema association, release cleanup wiring, or the moved logging API beyond the listing order delta described above.
