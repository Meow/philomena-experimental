# Bans SQL shape audit

Refs: master -> context-logic  
Status: complete

--- files ---

The Bans-owned query surface and moved callers reviewed:

- `lib/philomena/bans.ex`
- `lib/philomena/bans/finder.ex`
- `lib/philomena/bans/{user,subnet,fingerprint}.ex`
- `lib/philomena/bans/{user,subnet,fingerprint}_query_builder.ex`
- `lib/philomena/bans/{user,subnet,fingerprint}_query_form.ex`
- `lib/philomena/bans/id_generator.ex`
- `lib/philomena/user_fingerprints.ex`
- `lib/philomena/user_fingerprints/{user_fingerprint,fingerprint_profile,server}.ex`
- `lib/philomena/user_ips.ex`
- `lib/philomena/user_ips/{user_ip,ip_profile,server}.ex`
- `lib/philomena/profiles/fingerprint_history.ex`
- `lib/philomena_web/controllers/admin/{user_ban,subnet_ban,fingerprint_ban}_controller.ex`
- `lib/philomena_web/controllers/fingerprint_profile_controller.ex`
- `lib/philomena_web/controllers/ip_profile_controller.ex`
- `lib/philomena_web/plugs/{user_attribution_plug,filter_banned_users_plug}.ex`
- `lib/philomena_web/controllers/api/json/filter/user_filter_controller.ex`
- `lib/philomena_web/controllers/registration_controller.ex`
- `lib/philomena_web/plugs/api_require_authorization_plug.ex`
- `lib/philomena/workers/{user_erase_worker,user_wipe_worker,user_unvote_worker}.ex`
- `priv/repo/structure.sql`
- ban-related migration history, especially `20200617111116_prod_schema_sync_2020_06_17.exs`, `20210121200815_add_ban_duration_constraints.exs`, and `20240818182358_cleanup.exs`

The nested profile structs and ban schemas were also checked. They do not add
database queries; the `belongs_to` associations only affect the preload queries
listed below.

## Changed shapes

### 1. Effective-ban Finder

**Operation:** `Bans.find/3` -> `Finder.find/3`, called for request attribution
and API authorization. It builds zero to three branches and combines present
branches with `UNION ALL`.

Each branch in both refs has the same base shape:

- base table: one of `subnet_bans`, `fingerprint_bans`, `user_bans`;
- fixed predicates: `enabled = true` and `valid_until > now`;
- caller predicates: subnet `specification >>= ip`, fingerprint
  `fingerprint = value`, or user `user_id = current_user.id`;
- no joins, grouping, distinct, limit, offset, or database order;
- union is `UNION ALL`, followed by one `Repo.all`.

Classification: **changed, likely not index-relevant**. `context-logic` adds
`priority` and `sort_at = created_at` to the selected projection and chooses
the effective result in Elixir by `{priority, -created_at}`. The old version
returned the first union row (and, for signed-in users, the first user-ban
row). The predicates and access requirements are unchanged, and there is no
new SQL `ORDER BY`.

Correctness follow-up: the new explicit priority/newest selection appears to
make the result deterministic and gives user bans priority over subnet and
fingerprint bans. This is a behavior change, not an index recommendation.
The empty-input case is now explicitly handled (`[] -> []`) before unioning;
it has no SQL effect.

### 2. Fingerprint enforcement/profile lookup

**Operation:** `Bans.fingerprint_bans_for/1`, now used by the assembled
fingerprint profile in `UserFingerprints.show_fingerprint_profile/2`.

Master issued this query directly in
`FingerprintProfileController.show/2`; current code moved it to the context:

```text
FROM fingerprint_bans
WHERE fingerprint = $1
ORDER BY created_at DESC
```

Classification: **unchanged**. Projection, predicate, and ordering are the
same. The current helper does not add a tie-breaker, so equal timestamps remain
equivalent to master.

### 3. Subnet enforcement/IP-profile lookup

**Operation:** `Bans.subnet_bans_for_ip/1`, now used by the assembled IP profile
in `UserIps.show_ip_profile/2`.

The context-logic query is:

```text
FROM subnet_bans
WHERE specification >>= $1
ORDER BY created_at DESC
```

The enforcement equivalent already existed in `Finder.subnet_query/2`; the
profile-facing lookup was moved from the old controller/context boundary into
Bans. Classification: **new/moved, index-relevant but covered**. The
containment predicate is unchanged in access terms and the existing GiST
`subnet_bans(specification inet_ops)` index covers it. `created_at` is only a
secondary ordering after the containment search; no additional index is
recommended without workload/plan evidence.

### 4. Admin user-ban listing

Master had three controller branches, all based on `user_bans`, with a common
`ORDER BY created_at DESC`, preloading `user` and `banning_user`, and
`Repo.paginate`:

- default: no filter;
- `bq`: inner join `users` on the ban's `user_id`, then an OR of
  `users.name ILIKE '%q%'`, `generated_ban_id = q`, and full-text predicates on
  `reason` and `note`;
- `user_id`: `user_bans.user_id = value`.

Current `UserQueryBuilder` preserves those branches and adds `id DESC` as a
tie-breaker to the ordering. The context then preloads `user` and
`banning_user` and paginates.

Classification: **changed, index-relevant** for the ordering tie-breaker and
the retained dynamic listing workload; **changed, likely not index-relevant**
for the move and form parsing. The existing indexes cover the selective
branches:

- `index_user_bans_on_user_id` covers exact banned-user filtering;
- `users` primary key covers association lookup after the join;
- `index_user_bans_on_created_at` covers the existing date ordering (the
  current `id` tie-breaker does not justify a new composite index without
  plan and workload evidence).

The `bq` branch contains leading-wildcard `ILIKE` and computed
`to_tsvector(...)` fragments. A generic B-tree recommendation is not
appropriate. The exact generated-ban-ID equality is inside an OR with those
search predicates and has no standalone changed access path.

### 5. Admin subnet-ban listing

Master had default, `bq`, and `ip` controller branches over `subnet_bans`, with
`ORDER BY created_at DESC`, `banning_user` preload, and pagination. The `bq`
branch searched `generated_ban_id` plus full-text `reason`/`note`; the `ip`
branch used `specification >>= ip`.

Current `SubnetQueryBuilder` preserves those filters and adds `id DESC` as a
tie-breaker. Classification: **changed, index-relevant** for the ordering
tie-breaker and **covered** for the containment branch. Existing coverage:

- `index_subnet_bans_on_specification` is GiST with `inet_ops` and covers
  `specification >>= ip`;
- `index_subnet_bans_on_created_at` covers the date ordering;
- `users` primary key covers the `banning_user` preload.

The full-text/OR branch has the same specialized-search caveat as user bans;
no generic B-tree candidate is recommended.

### 6. Admin fingerprint-ban listing

Master had default, `bq`, and exact `fingerprint` controller branches over
`fingerprint_bans`, with `ORDER BY created_at DESC`, `banning_user` preload,
and pagination. Current `FingerprintQueryBuilder` preserves those filters and
adds `id DESC` as a tie-breaker.

Classification: **changed, index-relevant** for the ordering tie-breaker and
**covered** for exact fingerprint filtering. Existing coverage:

- `index_fingerprint_bans_on_fingerprint` covers the exact lookup;
- `index_fingerprint_bans_on_created_at` covers the date ordering;
- `users` primary key covers the `banning_user` preload.

The `bq` branch combines leading-wildcard fingerprint search, generated-ID
equality, and full-text fragments. It requires specialized analysis if it
becomes a bottleneck; no ordinary B-tree candidate is proposed.

### 7. Ban member loads and writes

Master loaded edit/update/delete resources by primary key through controller
plugs or `Repo.get!`; current `Bans.load_ban/5` uses `Loader.fetch/3` and then
authorization, with user-ban edit/update additionally preloading the target
user. These are primary-key member lookups, so they are **changed, likely not
index-relevant** due to context/authorization/preload composition. The primary
key indexes cover the ban loads. Changeset updates still target the loaded row
by primary key; no lookup predicate changed. Inserts, moderation-log writes,
and `Multi` transaction composition do not add a new row-selection shape.

`new_user_ban/3` and paired subnet creation add a target-user primary-key load
and `UserIps.latest_ip_for_user/1` (`user_id = ? ORDER BY updated_at DESC
LIMIT 1`). The latter is a moved/new caller shape but is owned by UserIps and is
covered by `index_user_ips_on_user_id_and_updated_at`.

## Unchanged or non-index-relevant sites

- `User`, `Subnet`, and `Fingerprint` schemas have only `belongs_to` ban-user
  associations and scalar fields; no schema association `where` clause changes
  SQL semantics.
- Admin listing preloads issue ordinary primary-key `users` lookups after the
  page query. They are covered by `users_pkey` and are unchanged in shape.
- `UserFingerprints` and `UserIps` now assemble fingerprint/IP profiles and
  call the Bans lookup helpers. Their history, cross-reference, delete, and
  batched upsert queries are separate context-owned workloads; the relevant
  ban-related latest-IP lookup is covered as noted above.
- `user_attribution_plug` now calls `Bans.find/3` once per request and stores
  the result in the actor/current-ban assigns. This moves the Finder workload
  to a central caller but does not change its relational predicates.
- `filter_banned_users_plug`, API authorization, registration checks, and
  existing controllers consume the result; they do not issue additional ban
  queries.
- The reviewed user workers do not add Bans queries. User wipe/erase and
  related deletion behavior is owned by Users; worker module movement alone is
  not a SQL shape change.
- Query forms only cast `bq`, `user_id`, `ip`, and `fingerprint`; builders add
  the branches described above and do not introduce hidden joins or scopes.

## New, deleted, moved, or ambiguous sites

- No Bans-owned query was deleted without a counterpart beyond the legacy CRUD
  helpers documented in the findings. Moved Finder/profile calls and the
  UserIps latest-IP lookup are linked to their owning contexts; no unresolved
  Bans query remains.

## Index inventory and recommendations

Existing relevant indexes in `priv/repo/structure.sql` are:

```text
fingerprint_bans: PRIMARY KEY (id)
  (banning_user_id), (created_at), (fingerprint)
subnet_bans: PRIMARY KEY (id)
  (banning_user_id), (created_at), GiST (specification inet_ops)
user_bans: PRIMARY KEY (id)
  (banning_user_id), (created_at DESC), (user_id)
user_ips: UNIQUE (ip, user_id), (updated_at), (user_id, updated_at DESC)
```

No new index candidate is recommended from this audit. The only changed
access requirements are the listing tie-breakers and moved subnet containment
lookup, and the existing date/GiST/foreign-key or primary-key coverage is
adequate on its face. The `bq` branches use leading-wildcard `ILIKE`, OR
grouping, and runtime `to_tsvector` fragments; they need representative
`EXPLAIN` plans, table cardinalities, and frequency data before considering
specialized expression/full-text or trigram indexes.

## Follow-ups

- Verify the intended priority/newest behavior of the effective-ban Finder and
  the deterministic `id DESC` listing tie-breakers as correctness concerns.
- Collect representative plans, cardinalities, and frequency data before
  considering specialized full-text/trigram indexes or a composite ordering
  index; no candidate is recommended from this audit.
