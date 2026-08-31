# Users SQL shape audit

Refs: master -> context-logic  
Status: complete  
Query sites inspected: 58

## Changed shapes

### Public profile member lookup (`show_profile/2`)

- Master: `lib/philomena_web/controllers/api/json/profile_controller.ex:10-14` — `users` member lookup by primary key `id = ?`, preload `public_links -> tag` and `awards -> badge`; deleted users were rejected in Elixir after the query.
- context-logic: `lib/philomena/users.ex:284-288` — `users` member lookup by `id = ?` plus fixed `deleted_at IS NULL`, with the same public-link and award preloads through `Loader.fetch_and_authorize/4`.
- Delta: index-relevant filter predicate added to the base member query; preload relation shapes are otherwise equivalent. This is also a correctness/visibility change: deactivated users are excluded by SQL before authorization/result rendering.
- Index status: covered
- Evidence: `users_pkey` covers `id`; `index_users_on_slug` is available for the slug form below. No separate `deleted_at` index is justified for a primary-key lookup. Current and master structure dumps have the same relevant user indexes.
- Confidence: high

### Potential profile aliases (`list_profile_aliases/2`)

- Master: `lib/philomena_web/controllers/profile/alias_controller.ex:25-42` — two collection queries over `users`, each inner-joining the subject user's `user_ips` or `user_fingerprints`, left-joining the matching table on `ip` or `fingerprint`, filtering `users.id <> subject_id` and matching-row `user_id = subject_id`, selecting users, preloading `bans`.
- context-logic: `lib/philomena/users.ex:2558-2610` — two `users` collection queries with `users.id <> subject_id` and `users.id IN (SELECT user_id FROM user_ips WHERE ip IN (SELECT ip FROM user_ips WHERE user_id = subject_id))`, respectively the analogous fingerprint subqueries; preloads `bans`.
- Delta: join-based match discovery became nested `IN` subqueries. The logical result is intended to be equivalent, but the planner-visible join shape and possible duplicate handling differ; this is index-relevant. The context also resolves the subject by `slug` via `load_user_by_slug/4` before these queries.
- Index status: covered
- Evidence: `index_user_ips_on_user_id_and_updated_at (user_id, updated_at DESC)` covers the subject-IP lookup's leading `user_id`; `index_user_ips_on_ip_and_user_id (ip, user_id)` covers reverse matching. `index_user_fingerprints_on_user_id (user_id)` and unique `index_user_fingerprints_on_fingerprint_and_user_id (fingerprint, user_id)` cover both directions. `users_pkey` covers the final user-id membership lookup; the `user_bans` preload is covered by `index_user_bans_on_user_id`. No new candidate is proposed without representative plans/cardinality.
- Confidence: high

### Permanent erasure query workflow (`Eraser.erase_permanently!/2`)

- Master: `lib/philomena/users/eraser.ex:25-81` — selects all `posts`, `comments`, `galleries`, `topics`, and `source_changes` by `user_id` (source changes ordered `created_at DESC`, preloaded `image`), deletes all source changes by `user_id`; report closure delegated to `Reports.close_reports/2`.
- context-logic: `lib/philomena/users/eraser.ex:32-134` — same user-id selections; post and topic selections preload `topic -> forum` / `forum`; gallery selects only `id`; source changes retain `created_at DESC` but no longer preload `image`; reports are selected by `reported_user_id = ? AND open = true`, selecting IDs before per-report close operations.
- Delta: added association preloads change follow-up SQL (posts/topics), gallery projection changes only selected columns, source-change preload was removed, and report closure now has an explicit indexed collection query. Existing `user_id` indexes cover all attribution selections; `reports_reported_user_id_index` is a partial index on non-null `reported_user_id`, while `index_reports_on_open` covers `open`. A composite `(reported_user_id, open)` index could be considered only with workload/plan evidence; no candidate is recommended from this audit.
- Index status: covered
- Evidence: `index_posts_on_user_id`, `index_comments_on_user_id`, `index_galleries_on_creator_id`, `index_topics_on_user_id`, and `index_source_changes_on_user_id` exist. `reports_reported_user_id_index` plus `index_reports_on_open` cover the new report predicate, though not as one composite path. The changed preloads issue their owning contexts' queries and are not Users-owned shape changes.
- Confidence: high

### User wipe workflow (`Users.UserWipe.perform/1`)

- Master: `lib/philomena/user_wipe.ex:15-42` — for each attribution table, batch-select rows by `user_id` and `UPDATE` IP/fingerprint; `DELETE FROM user_ips WHERE user_id = ?`; `DELETE FROM user_fingerprints WHERE user_id = ?`; `UPDATE users SET email = ? WHERE id = ?`.
- context-logic: `lib/philomena/users/user_wipe.ex:29-48`, with delegated implementations in `Comments.wipe_user_attribution!/3`, `Images.wipe_user_attribution!/3`, `Posts.wipe_user_attribution!/3`, `Reports.wipe_user_attribution!/3`, `SourceChanges.wipe_user_attribution!/3`, `TagChanges.wipe_user_attribution!/3`, `UserIps.delete_for_user!/1`, `UserFingerprints.delete_for_user!/1`, and `Users.replace_email_for_wipe!/2`.
- Delta: query ownership and batching moved into the owning contexts; the Users-level write predicates remain user-id deletes and primary-key email update. The former direct wipe also updated `Report`/`TagChange` attribution rows; current calls preserve that workload through delegated context APIs. The reindex query is non-SQL/OpenSearch and excluded.
- Index status: covered
- Evidence: user-id foreign-key indexes cover the delegated attribution updates/deletes; `index_user_ips_on_user_id`, `index_user_fingerprints_on_user_id`, and `users_pkey` directly cover the Users-owned predicates. The exact delegated SQL is a cross-context/shared follow-up, not duplicated here.
- Confidence: medium

## Unchanged or non-index-relevant sites

- `load_user_by_slug/4` (`lib/philomena/users.ex:64-71`) is the context replacement for the master authorization/resource loaders used by profile and admin controllers. It is `users.slug = ?` with optional preloads; `index_users_on_slug` covers it. The admin edit/update/activation/API-key/avatar/force-filter/unlock/verification/vote/downvote/erase/wipe operations all reuse this locator, so their lookup shape is unchanged apart from the explicit public-profile `deleted_at IS NULL` branch.
- `get_user_by_authentication_token/1` (`users.ex:486-490`), `get_user_by_email/1` (`:506-508`), and the email/password lookup in `fetch_user_by_email_and_password/3` (`:529-585`) retain equality lookups on unique `authentication_token`/`email`; subsequent changeset `UPDATE users` statements select the already-loaded primary-key row.
- Registration and token-generation inserts (`create_registration/1`, `generate_user_session_token/1`, `generate_user_totp_token/1`, and email-token delivery functions) do not change row-selection predicates. The session/TOTP/email/reset/reactivation token reads at `users.ex:684-742`, `:905-1052`, `:1100-1224` use `UserToken` builders with the same normalized shapes as master: `user_tokens.token = ? AND context = ?`, optional `created_at > cutoff`, joins to `users` for email validation, and (for TOTP) `user_id = ?`. `user_tokens_context_token_index (context, token)` and `user_tokens_user_id_index (user_id)` cover these lookups; email validation is a join to the users primary key.
- `verify_session_token_query_with_timestamp/1` (`users/user_token.ex:48-62`) is a new paired projection of the existing session-token query, selecting `{user, created_at}` rather than `user`; it is a moved/extended result shape with identical filters, join, and index requirements.
- Token cleanup in `user_email_multi/3`, `unlock_user_multi/1`, `confirm_user_multi/1`, `update_password/2`, `create_reactivation/1`, `delete_user_sessions/1`, `delete_totp_token/1`, and `delete_session_token/1` (`users.ex:77-99`, `:468`, `:814`, `:1173-1230`, `:977`, `:1052`) uses the same `user_id = ?` or `(token, context)` delete predicates as master; covered by the two user-token indexes.
- `fetch_roles/1` (`users.ex:130-133`) is `roles.id IN (?)`, covered by the role primary key. `admin_user_form/1` (`:123-127`) loads all roles without filters. `load_user_with_roles/1` (`:164-173`) and `user_lock_query/1` (`:197-201`) use primary-key user lookup plus association preloads; `Multi.lock_one` callers at the administrative mutation sites retain the same `users.id = ? FOR UPDATE` access path.
- `staff_categories/0` (`users.ex:393-400`) is a collection filter `users.role IN ('admin','moderator','assistant') ORDER BY name ASC`; it is new context-owned SQL only if executed, but is a stable staff-list workload rather than a master/context shape pair. Existing partial `index_users_on_role` covers the role predicate; no index action is proposed for the un-covered name ordering without plan evidence.
- `list_profile_aliases/2` subject locators, `preload(:bans)`, `load_report_target/2`, and `preload_preview_awards/1` (`users.ex:308-376`) preserve member/preload shapes; association SQL belongs to the owning contexts.
- Counter and maintenance writes (`put_replace_watched_tag/4` at `users.ex:2687-2698`, `increment_counter/4`, `increment_counters/4`, `replace_email_for_wipe!/2`) retain `watched_tag_ids @> ARRAY[?]`, `users.id = ?`, and `users.id IN (?)` predicates. The watched-tag query is covered by `index_users_on_watched_tag_ids` (GIN); primary-key predicates are covered by `users_pkey`.
- `fetch_user_for_worker!/1`, `fetch_user_for_erase!/1`, `perform_reindex/2`, and `indexing_preloads/0` (`users.ex:2808-2871`) are unchanged member/index-maintenance query shapes. OpenSearch definitions and reindex requests were inspected and excluded by the audit rules.
- `users/settings_backfill.ex:44-61` is a raw SQL maintenance insert into `user_settings` selecting users by `id`; it is unchanged and its source is a migration/backfill operation, not a changed lookup predicate.
- `users/user_downvote_wipe.ex:20-23` only performs the unchanged image reindex selection `images.id IN (?)`; the actual vote/fave batch deletes and counter updates are now delegated and owned by interaction contexts.
- User changesets (`users/user.ex`) issue updates against loaded rows by primary key; validation additions, role associations, approval flags, password hashing, and selected columns do not alter row-selection predicates.

## New, deleted, moved, or ambiguous sites

- `lib/philomena_web/user_loader.ex` and the master admin user controller's `Search.search_records(User)` path moved to `Users.query_users/3` plus `Users.QueryBuilder`/`QueryForm` (`users.ex:1799-1813`). This is OpenSearch request construction, not PostgreSQL SQL; no SQL shape is classified.
- The master profile controller's SQL-heavy assembled page moved to `Profiles.show_profile/4` and related profile modules. Its SQL sites (galleries, statistics, watcher counts, bans, identity histories and profile preloads) are owned by the Profiles wave; this report records the Users locator boundary only. The former `Repo.preload(conn.assigns.user, [:forced_filter])` is represented by the Users profile result's `forced_filter` association and has unchanged foreign-key lookup semantics.
- Master `user_wipe.ex` was deleted and replaced by `users/user_wipe.ex`; the query ownership split is described under Changed shapes. Exact SQL inside delegated `wipe_user_attribution!` and deletion APIs must be reconciled with their owning context reports/shared report.
- `Users.UserWipe` now calls `Users.fetch_user_for_worker!/1`, while master called `Users.get_user!/1`; both are `users.id = ?` member lookups.
- The branch introduces new context APIs and authorization/loader calls (`Loader.fetch_and_authorize`, `Loader.one_and_authorize`) whose final visibility/authorization SQL should be canonicalized in the shared report. This report does not duplicate Loader internals.
- Migration/schema history was checked. `master` and `context-logic` differ in unrelated migration files and the structure dump, but no Users/UserToken index relevant to these shapes changed. Relevant history includes `20200725234412_create_users_auth_tables.exs`, the user indexes from the production schema sync migrations, and `20220321173359_add_approval_queue.exs`; no follow-up migration is warranted from this audit alone.

## Follow-ups

- Profiles/shared report should link back to the `show_profile/2` locator and canonicalize Loader authorization/preload behavior.
- Confirm with representative `EXPLAIN (FORMAT JSON)` on realistic `user_ips`/`user_fingerprints` cardinalities whether the rewritten alias subqueries outperform the old joins; existing indexes cover both forms, so this is plan evidence rather than an index recommendation.
- Confirm whether the new report closure selection (`reported_user_id = ? AND open = true`) is frequent enough to merit a composite `(reported_user_id, open)` or partial `(reported_user_id) WHERE open` index. Current separate partial reported-user and open indexes are adequate evidence for “no automatic candidate.”
- The erasure path now uses per-row domain operations and association preloads, which may change query count and transaction behavior without changing the primary lookup indexes; review as a workload/correctness concern in the owning Reports/Posts/Topics/SourceChanges reports.
