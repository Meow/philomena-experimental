# Profiles SQL shape audit

Refs: master -> context-logic  
Status: complete  
Query sites inspected: 18 logical sites (including profile-page SQL, association preloads, admin metadata, name/IP/fingerprint histories, and delegated source/tag-history entry points)

## Changed shapes

### Profile IP history pagination and deterministic ordering

- Master: `lib/philomena_web/controllers/profile/ip_history_controller.ex:20-38`, `PhilomenaWeb.Profile.IpHistoryController.index/2`; primary query was `user_ips` filtered by `user_id = ?`, preloaded `user`, ordered `updated_at DESC`, and returned with `Repo.all`; follow-up query filtered `ip IN (...)`, preloaded `user`, and ordered `updated_at DESC`.
- context-logic: `lib/philomena/user_ips.ex:36-49,105-117`, `Philomena.UserIps.load_user_history/3`; primary query is `user_id = ? ORDER BY updated_at DESC, id DESC LIMIT/OFFSET`, paginated, followed by the same `ip IN (...)` cross-reference query with `user` preload and `updated_at DESC`. `Profiles.list_profile_ip_history/3` calls this at `lib/philomena/profiles.ex:349-354`.
- Delta: collection became a bounded page; `id DESC` was added as a tie-breaker; the primary-page `user` preload was removed (the template only uses the page row's IP, while cross-reference rows still preload users). The cross-reference set is now derived from the current page rather than every historical row.
- Index status: covered
- Evidence: `priv/repo/structure.sql:4451-4454` has `index_user_ips_on_user_id_and_updated_at (user_id, updated_at DESC)`, covering the equality prefix and requested primary ordering. `index_user_ips_on_ip_and_user_id (ip, user_id)` covers the cross-reference membership predicate; its `updated_at` ordering is not covered, but the query is bounded by the page's distinct IPs and existed before the refactor. No local EXPLAIN was run because the audit is source/schema-only and no representative dataset was established.
- Confidence: high

### Profile fingerprint history pagination and deterministic ordering

- Master: `lib/philomena_web/controllers/profile/fp_history_controller.ex:20-38`, `PhilomenaWeb.Profile.FpHistoryController.index/2`; primary query was `user_id = ?`, preloaded `user`, ordered `updated_at DESC`, and returned with `Repo.all`; follow-up query filtered `fingerprint IN (...)`, preloaded `user`, and ordered `updated_at DESC`.
- context-logic: `lib/philomena/user_fingerprints.ex:41-54,111-123`, `Philomena.UserFingerprints.load_user_history/3`; primary query is `user_id = ? ORDER BY updated_at DESC, id DESC LIMIT/OFFSET`, paginated, followed by the same `fingerprint IN (...)` cross-reference query with `user` preload and `updated_at DESC`. `Profiles.list_profile_fingerprint_history/3` calls this at `lib/philomena/profiles.ex:372-381`.
- Delta: same page-bound and tie-breaker changes as IP history; the primary-page `user` preload was removed, while cross-reference users remain preloaded.
- Index status: needs plan evidence
- Evidence: `priv/repo/structure.sql:4430-4433` has only `index_user_fingerprints_on_user_id (user_id)` for the primary filter, and `:4422-4426` has unique `(fingerprint, user_id)` for cross-reference membership. Neither fully supplies `ORDER BY updated_at DESC, id DESC`; a candidate would be `(user_id, updated_at DESC, id DESC)`, but the page is bounded and workload/cardinality plus EXPLAIN evidence are unavailable. Do not add an index based on this audit alone.
- Confidence: high

## Unchanged or non-index-relevant sites

- `Philomena.Profiles.show_profile/4` (`lib/philomena/profiles.ex:246-255`) is a relocation of `ProfileController.show/2` (`master:lib/philomena_web/controllers/profile_controller.ex:43-184`). The SQL-bearing portions are unchanged: `users` profile loading is delegated to `Users.load_profile/2`; `@profile_preloads` preserves forced-filter, public/verified-link predicates, awards, commission, image, source, tag, and alias preloads; recent galleries remain `galleries WHERE user_id = ? AND anonymous = false LIMIT 4`; watcher counts remain tag-ID `IN` plus lateral `count(*) FROM users WHERE watched_tag_ids @> ARRAY[tag.id]`; statistics remain `user_statistics WHERE user_id = ? AND day >= ?`; bans remain `user_bans WHERE user_id = ? ORDER BY created_at DESC`. OpenSearch definitions and result preloads were inspected but are outside PostgreSQL scope.
- `Profiles.load_admin_metadata/2` (`lib/philomena/profiles.ex:276-289`) replaces the controller's `set_admin_metadata/2` (`master:lib/philomena_web/controllers/profile_controller.ex:237-263`). The current IP/fingerprint latest calls use the history query with the added `id DESC` tie-breaker before `LIMIT 1`; this is the same index-relevant ordering delta covered above. `Repo.preload(user, [:current_filter])` is unchanged in relational effect.
- `Profiles.load_name_changes/2` (`lib/philomena/profiles.ex:325-331`) replaces `set_name_changes/2` (`master:lib/philomena_web/controllers/profile_controller.ex:277-291`). The delegated query remains `user_name_changes WHERE user_id = ? ORDER BY id DESC`, now paginated to the fixed `{page: 1, page_size: 250}`. The added bound is an access-path change, but existing `index_user_name_changes_on_user_id` (`structure.sql:4458-4462`) covers the filter; no separate index action is proposed.
- The user schema association predicates inspected at `lib/philomena/users/user.ex:31-49` are unchanged: `public_links` adds `public = true AND aasm_state = 'verified'`, and `verified_links` adds `aasm_state = 'verified'`. Their preloads are part of the profile operation but are owned by ArtistLinks/shared association loading.
- `Profiles.load_mod_notes/3` (`lib/philomena/profiles.ex:307-310`) delegates to `ModNotes.list_for_target/3`; the profile wrapper does not alter that query shape. Canonical shared-context review belongs in the ModNotes/shared report.
- Profile source history remains delegated: current `Profile.SourceChangeController.index/2` (`lib/philomena_web/controllers/profile/source_change_controller.ex:9-37`) calls `SourceChanges.list_user_source_changes/4`, just as the master controller's direct query (`master:lib/philomena_web/controllers/profile/source_change_controller.ex:20-50`) had `source_changes.user_id = ?`, image join, anonymous-own-upload exclusion, optional `added` predicate, `ORDER BY id DESC`, pagination, and distinct-image count. The canonical query is owned by SourceChanges; no Profiles-specific shape change was found.
- Profile tag history is a new nested controller entry point (`lib/philomena_web/controllers/profile/tag_change_controller.ex:9-37`) calling `TagChanges.list_user_tag_changes/4`. Master exposed the equivalent user attribution through the generic tag-change controller/template. The SQL/search shape is owned by TagChanges and the wrapper adds no PostgreSQL query.
- `UserIps.show_ip_profile/2` and `UserFingerprints.show_fingerprint_profile/2` are profile-shaped operations but are owned by their respective contexts; their current `ip >>= ?` / `fingerprint = ?` lookups, user preloads, and ban lookups were inspected as delegated operations. No Profiles-side query delta was found.

## New, deleted, moved, or ambiguous sites

- `lib/philomena/profiles.ex` and `lib/philomena/profiles/*` are new context files, not new database workloads: the public profile assembly and admin/name-history calls moved from `PhilomenaWeb.ProfileController`, while IP/fingerprint page queries moved from their two controllers into `UserIps`/`UserFingerprints` and are composed by Profiles.
- The primary IP/fingerprint history `user` preload is absent in context-logic. This appears intentional and is sufficient for the current templates (`lib/philomena_web/templates/profile/{ip_history,fp_history}/index.html.slime:11-22`), which only dereference `u.user` for cross-reference rows. Verify this assumption if another caller consumes `Scrivener.Page.entries` directly.
- No worker or maintenance SQL is owned by `Philomena.Profiles`; IP/fingerprint persistence and user erasure remain owned by `UserIps`, `UserFingerprints`, and `Users.UserWipe`.
- `priv/repo/structure.sql` has no Profiles-specific schema/index delta between refs. Relevant migration history inspected includes the historical user-IP/fingerprint/name/statistics indexes and `20260718000000_user_statistics_day_to_date.exs`; current and master dumps agree on the relevant indexes.

## Follow-ups

- Link the fingerprint-history finding to the UserFingerprints/shared synthesis. Run representative `EXPLAIN (FORMAT JSON)` for `user_fingerprints WHERE user_id = ? ORDER BY updated_at DESC, id DESC LIMIT/OFFSET` before considering `(user_id, updated_at DESC, id DESC)`; compare it with the existing `user_id` index and table/cardinality statistics.
- Reconcile the removed primary-page preloads with any non-template callers. This is a possible API/association-loading correctness issue, not an automatic index recommendation.
- SourceChanges and TagChanges should remain canonical owners for profile source/tag history; avoid duplicating those findings in the Profiles index summary.
