# UserFingerprints SQL shape audit

Refs: master -> context-logic
Status: complete

--- status ---

Audited the UserFingerprints context and nested `FingerprintProfile`, `Server`,
and `UserFingerprint` modules, plus the legacy fingerprint-profile/history
controllers, profile metadata caller, updater, wipe path, `User` association,
the Users-owned alias caller, the Bans fingerprint helper, and data-export
schema use. Query sites inspected: 24 source/query sites and generated
pagination branches across both refs.

The `user_fingerprints` table is unchanged for relevant indexes between the
refs. `master` and `context-logic` both have the primary key on `id`, unique
`(fingerprint, user_id)`, ordinary `user_id`, and the foreign key on
`user_id`.

## Changed shapes

### Paginated user fingerprint history (`load_user_history/3`)

- Master: `lib/philomena_web/controllers/profile/fp_history_controller.ex:20-25` (`index/2`) selected all rows from `user_fingerprints` with `user_id = ?`, ordered by `updated_at DESC`, preloaded `user`, and issued an unbounded `Repo.all`. The preload issued the usual user-PK lookup.
- context-logic: `lib/philomena/user_fingerprints.ex:41-45,111-123` (`history_query/1`, `load_user_history/3`) uses `user_id = ?`, `ORDER BY updated_at DESC, id DESC`, then `Repo.paginate`. The page query adds `LIMIT/OFFSET`; Scrivener also issues `count(*)` over the same `user_id` predicate after excluding order/preload. The page-row `user` preload was removed; `cross_references/1` still preloads users for the page's distinct fingerprints.
- Delta: changed from an unbounded collection to count plus paginated collection; added deterministic `id DESC` tie-breaker; removed the page-row user preload. The cross-reference query remains `fingerprint IN (...) ORDER BY updated_at DESC` with a user preload, but its values are now derived from the current page rather than the entire history.
- Index status: confirmed follow-up candidate (human production review)
- Evidence: existing `index_user_fingerprints_on_user_id` covers the equality filter and count, but not the requested ordering. A read-only dev `EXPLAIN (FORMAT JSON)` for the representative page shape chose a bitmap scan on that index followed by a sort on `updated_at DESC, id DESC`. The focused production review reports request timeouts on current `master` deployments and confirms `CREATE INDEX ... ON user_fingerprints (user_id, updated_at DESC, id DESC)`. The dev relation is only 8 KB and has no collected statistics (`reltuples = -1`), so the production plan/size evidence should be captured with migration review; this source audit does not claim the dev plan is representative.
- Confidence: medium

### Latest fingerprint row (`latest_for_user/2`)

- Master: `lib/philomena_web/controllers/profile_controller.ex:249-254` (`set_admin_metadata/2`) used `user_id = ?`, `ORDER BY updated_at DESC`, `LIMIT 1`, and `Repo.one`.
- context-logic: `lib/philomena/user_fingerprints.ex:41-45,139-145` (`history_query/1`, `latest_for_user/2`) uses `user_id = ?`, `ORDER BY updated_at DESC, id DESC`, `LIMIT 1`, and `Repo.one`, after the context authorization gate.
- Delta: added the `id DESC` tie-breaker; the query moved into the UserFingerprints context. The same composite candidate as the paginated history query serves this limit-1 access path.
- Index status: confirmed follow-up candidate (same index as history)
- Evidence: the existing `user_id` index supplies the filter but the representative dev plan still sorts; `(user_id, updated_at DESC, id DESC)` matches equality columns followed by ordering/tie-breaker. The focused production review confirms this candidate for the latest-row path.
- Confidence: medium

### Users-owned fingerprint alias lookup (cross-context finding)

- Master: `lib/philomena_web/controllers/profile/alias_controller.ex:35-43` (`index/2`, `fp_matches`) joined `users` to `user_fingerprints` for the candidate user, joined a second `user_fingerprints` relation on equal `fingerprint`, then filtered the second relation to the target `user_id` and excluded the target user.
- context-logic: `lib/philomena/users.ex:2566-2595` (`list_profile_aliases/2`) first selects target fingerprints by `user_id`, selects matching user IDs by `fingerprint IN (subquery)`, then filters `users.id IN (subquery)` and preloads bans.
- Delta: join chain changed to two fingerprint subqueries plus an outer user-ID semi-join; duplicate-producing join rows are avoided. This is owned by Users, not a UserFingerprints public operation.
- Index status: covered
- Evidence: target-fingerprint lookup is covered by `index_user_fingerprints_on_user_id`; matching `fingerprint IN (...)` with `user_id` output is covered by the unique `(fingerprint, user_id)` index; the outer user lookup uses the users primary key. No UserFingerprints index action is indicated.
- Confidence: high

## Unchanged or non-index-relevant sites

- Fingerprint profile history lookup moved from `lib/philomena_web/controllers/fingerprint_profile_controller.ex:12-17` to `lib/philomena/user_fingerprints.ex:33-39` (`user_fingerprints_for/1`): exact `fingerprint = ?`, `ORDER BY updated_at DESC`, preload `user`, and `Repo.all` are unchanged relationally. The unique `(fingerprint, user_id)` index covers the filter; the ordering sort is an existing workload characteristic, not a changed shape. Current input normalization/validation and the switch from `:ip_address` to `:identity_metadata` authorization are semantic changes, not index changes.
- Fingerprint-ban lookup moved from the same legacy controller (`:19-23`) to `Philomena.Bans.fingerprint_bans_for/1` at `lib/philomena/bans.ex:48-52`: exact `fingerprint = ?`, `ORDER BY created_at DESC`, `Repo.all`; `index_fingerprint_bans_on_fingerprint` covers the predicate. The query is Bans-owned.
- History cross-reference retrieval moved from `profile/fp_history_controller.ex:32-38` to `cross_references/1` at `user_fingerprints.ex:47-54`: same `fingerprint IN (...)`, `ORDER BY updated_at DESC`, user preload, `Repo.all`, and grouping shape. Its input set is page-bounded in the new operation, which changes workload volume but not the relational shape.
- The asynchronous updater moved from `PhilomenaWeb.UserFingerprintUpdater.run/0` (`lib/philomena_web/user_fingerprint_updater.ex:31-40`) to `persist_usage_batch/1` and `Server` (`lib/philomena/user_fingerprints.ex:162-184`, `server.ex:34-56`). The `INSERT ... ON CONFLICT (user_id, fingerprint) DO UPDATE` target and `uses/updated_at` update are unchanged; the unique index covers the conflict target.
- User-wipe deletion moved from `lib/philomena/user_wipe.ex:31-37` to `Philomena.UserFingerprints.delete_for_user!/1` at `user_fingerprints.ex:149-155`, retaining `DELETE FROM user_fingerprints WHERE user_id = ?`; the ordinary `user_id` index covers it. The schema's `uses` default changed from `0` to `1`, and changeset/insert-row construction changed, but neither changes SQL row selection.
- `User.has_many(:user_fingerprints)` in `lib/philomena/users/user.ex:34-38` is unchanged. Association preloads use the `users` primary key for the related user rows; no new index is needed.
- `DataExports.Aggregator` continues to select UserFingerprint export rows by `user_id` through its existing batch mechanism at `lib/philomena/data_exports/aggregator.ex:75-80`; the schema alias and selected columns are unchanged.

## New, deleted, moved, or ambiguous sites

- The generated CRUD surface in `master:lib/philomena/user_fingerprints.ex` (`list_user_fingerprints/0`, `get_user_fingerprint!/1`, `create_user_fingerprint/1`, `update_user_fingerprint/2`, and `delete_user_fingerprint/1`) was removed. Repository-wide caller search found only their definitions/docs, so these are deleted unused APIs rather than deleted production workloads. The former list/get paths were respectively an unfiltered scan and primary-key lookup; the latter writes/deletes were changeset/primary-key operations. No index action follows.
- `FingerprintProfile` and the new `Server` contain no independent query shape. `Server` delegates its flush to `persist_usage_batch/1`; `FingerprintProfile` is a result struct.
- No relevant `user_fingerprints` migration changed between the refs. The only `structure.sql` differences are unrelated commission uniqueness, image-intensity cascade, and dump metadata/schema-migration entries. Relevant index definitions are present in both structure dumps; migration history contains no branch change adding or removing a UserFingerprint index.

## Follow-ups

- The focused production review confirms `(user_id, updated_at DESC, id DESC)` as a follow-up index for history/latest timeout pressure. Before migration, capture production-sized `EXPLAIN (ANALYZE, BUFFERS)`, index-size, and build/lock timing; the local read-only plan demonstrates the current filter-then-sort path but is not representative due to the empty/unanalyzed dev table.
- The current profile path intentionally normalizes/validates fingerprints before authorization and authorizes `:identity_metadata` instead of the legacy `:ip_address`; review that behavioral change separately from SQL/index concerns.
- The fingerprint alias query is a Users-owned shape change and should be linked from the Users report; this report records it only to account for the moved caller and its UserFingerprint index coverage.
