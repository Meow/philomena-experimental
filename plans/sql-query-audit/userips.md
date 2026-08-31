# UserIps SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 8 UserIps-owned operation shapes, plus delegated and moved consumers

## Changed shapes

### Paginated IP history and latest staff IP row

- Master: `lib/philomena_web/controllers/profile/ip_history_controller.ex:20-25`
  selected all `user_ips` rows for `user_id = $user_id`, preloaded `user`, and
  ordered by `updated_at DESC`; `lib/philomena_web/controllers/profile_controller.ex:242-247`
  used the same predicate/order with `LIMIT 1` for the staff profile.
- context-logic: `lib/philomena/user_ips.ex:36-40,105-110` defines the shared
  history relation as `user_id = $user_id ORDER BY updated_at DESC, id DESC`.
  `load_user_history/3` applies Scrivener `LIMIT/OFFSET` and also issues its
  count query; `lib/philomena/user_ips.ex:133-139` applies `LIMIT 1` for
  `latest_for_user/2`.
- Delta: the history collection changed from an unbounded `Repo.all` to a
  paginated page plus total-count query, its main-row `user` preload was
  removed because the caller already has the user, and both retained history
  paths gained `id DESC` as a deterministic tie-breaker. The added tie-breaker
  is a correctness/order change as well as a possible access-path change.
- Index status: confirmed follow-up candidate (human production review)
- Evidence: `index_user_ips_on_user_id_and_updated_at` covers the equality
  predicate and primary ordering but not the deterministic `id` tie-breaker.
  The focused production review confirms replacing it with
  `(user_id, updated_at DESC, id DESC)` for timeout-prone history/latest reads.
  The new index has the old index as an exact prefix, so removal of the old
  two-column index is defensible for the audited query set; verify repository-
  wide index usage and foreign-key maintenance behavior before dropping it.
- Confidence: high

## Unchanged or non-index-relevant sites

- IP-profile observed-user lookup moved from
  `lib/philomena_web/controllers/ip_profile_controller.ex:19-24` to
  `lib/philomena/user_ips.ex:28-34`. Both issue `user_ips` with the inet
  containment predicate `ip >>= $ip`, `ORDER BY updated_at DESC`, and a
  `user` preload. The authorization and IP parsing moved into the context but
  do not change SQL shape. The existing B-tree `(ip, user_id)` is not evidence
  of efficient inet-containment support; this workload is unchanged and no
  delta-only index action is raised here.
- IP-history cross-references moved from
  `lib/philomena_web/controllers/profile/ip_history_controller.ex:32-38` to
  `lib/philomena/user_ips.ex:42-48`. Both use `WHERE ip IN ($page_ips)`, a
  `user` preload, and `ORDER BY updated_at DESC`, followed by application-side
  grouping. `index_user_ips_on_ip_and_user_id` covers the exact-IP predicate.
- Automatic latest-IP scalar lookup moved from
  `Philomena.UserIps.get_ip_for_user/1` at
  `lib/philomena/user_ips.ex:31-37` and its master caller
  `lib/philomena/bans/subnet_creator.ex:19` to
  `lib/philomena/user_ips.ex:151-157`, called from
  `lib/philomena/bans.ex:631`. The shape remains `user_id = $user_id`,
  `ORDER BY updated_at DESC`, `LIMIT 1`, selecting `ip`; the existing
  `(user_id, updated_at DESC)` index covers it. Unlike the staff-row path, it
  has no `id` tie-breaker in either ref.
- User IP erasure moved from
  `lib/philomena/user_wipe.ex:31-33` to
  `lib/philomena/user_ips.ex:163-166` and remains
  `DELETE FROM user_ips WHERE user_id = $user_id`. The existing composite
  user/order index supplies the `user_id` access path; no new index is needed.
- Usage batching moved from
  `lib/philomena_web/user_ip_updater.ex:28-33` to
  `lib/philomena/user_ips.ex:173-192`. For a non-empty batch both refs issue
  the same multi-row insert/upsert with `ON CONFLICT (user_id, ip)`, increment
  `uses`, and set `updated_at` from `EXCLUDED`; the current empty-map guard
  merely avoids an empty write. The unique `(ip, user_id)` index covers the
  same conflict column set; PostgreSQL conflict inference does not require
  the index columns to be listed in the same order.
- The `has_many :user_ips, UserIp` association is unchanged in
  `lib/philomena/users/user.ex` at the corresponding association lines and has
  no `where` or ordering clause, so it adds no preload query-shape delta.
- The IP-profile subnet-ban query remains owned by `Bans`: it moved from
  `lib/philomena_web/controllers/ip_profile_controller.ex:26-30` to
  `lib/philomena/bans.ex:286-295` with the same specification-containment
  predicate and `created_at DESC` ordering. It is included in the
  `show_ip_profile/2` operation but is not a UserIps-owned query.
- `UserIp` schema changes in `lib/philomena/user_ips/user_ip.ex:9-28`
  (types, default `uses`, and changeset fields) affect data validation or
  defaults, not PostgreSQL query shape. The structure dump still defines the
  same `user_ips` columns in both refs.

## New, deleted, moved, or ambiguous sites

- `show_ip_profile/2`, `load_user_history/3`, and `latest_for_user/2` are new
  context APIs pairing the controller/profile workloads described above; they
  are not new independent workloads except for the intentional pagination and
  tie-breaker changes.
- Master-only `get_user_ip!/1`, `create_user_ip/1`, `update_user_ip/2`,
  `delete_user_ip/1`, and `change_user_ip/1` are removed from
  `lib/philomena/user_ips.ex`. Repository search found no production callers
  for these legacy helpers. The getter had a primary-key member lookup; the
  remaining helpers were generic changeset/write wrappers and do not justify
  an index recommendation.
- The IP half of potential-alias matching moved out of the web controller:
  master `lib/philomena_web/controllers/profile/alias_controller.ex:25-33`
  used a `users` base query with an inner `user_ips` association join and a
  left `user_ips` join on equal IPs, while context-logic
  `lib/philomena/users.ex:2561-2587` uses nested `IN` subqueries to collect
  target IPs and matching user IDs. This is a real SQL-shape delta, but the
  query is owned by `Users`, not `UserIps`; it should be audited there and not
  duplicated as a UserIps recommendation.
- No other UserIps-owned worker, maintenance, `Repo.preload`,
  `delete_all`, `update_all`, or `Philomena.Multi` query was found in either
  ref. `UserIps.Server` only batches in memory and delegates its write to
  `persist_usage_batch/1`.

## Index and migration evidence

- The relevant `user_ips` definition is unchanged between the refs in
  `priv/repo/structure.sql`: primary key `user_ips_pkey (id)`, unique B-tree
  `index_user_ips_on_ip_and_user_id (ip, user_id)`, ordinary B-tree
  `index_user_ips_on_updated_at (updated_at)`, and B-tree
  `index_user_ips_on_user_id_and_updated_at (user_id, updated_at DESC)`.
  The `user_id` foreign key to `users(id)` is also unchanged.
- The relevant indexes are present in the initial structure history at commit
  `80c8b744` (`add structure file`). `20200617113333_prod_schema_sync2.exs`
  only adjusts the `user_ips` sequence type; no migration between `master` and
  `context-logic` adds, removes, or changes a UserIps index.
- The focused production review confirms replacing the two-column ordering
  index with `(user_id, updated_at DESC, id DESC)`. The replacement retains the
  old index's prefix coverage; validate index usage/size and drop timing before
  removing the redundant two-column index.

## Follow-ups

- Capture production-sized plans and index-size/build timing for
  `(user_id, updated_at DESC, id DESC)` before rollout, and verify no
  non-audited query depends on retaining the old two-column index.
- Keep the inet-containment profile query and alias cross-reference assigned to
  their owning Bans/Users findings during shared synthesis.
