# Donations SQL shape audit

Refs: master -> context-logic
Status: complete

--- files ---
priv/repo/structure.sql
priv/repo/migrations/20200617111116_prod_schema_sync_2020_06_17.exs
priv/repo/migrations/20200617113333_prod_schema_sync2.exs
priv/repo/migrations/20240818182358_cleanup.exs
lib/philomena/donations.ex
lib/philomena/donations/donation.ex
lib/philomena/users/user.ex
lib/philomena/loader.ex
lib/philomena/repo.ex
lib/philomena/data_exports/aggregator.ex
lib/philomena_web/controllers/admin/donation_controller.ex
lib/philomena_web/controllers/admin/donation/user_controller.ex
lib/philomena_web/plugs/canary_plugs.ex
deps/canary/lib/canary/plugs.ex

Query sites inspected: 8

no SQL shape changes found

## Changed shapes

### Admin donation listing (`list_donations/2`)

- Classification: `unchanged`.
- Master: `lib/philomena_web/controllers/admin/donation_controller.ex:9-18` builds
  a `donations` query with all schema columns, no filter or join,
  `ORDER BY created_at DESC, user_id ASC`, Scrivener `LIMIT/OFFSET`, and a
  `users` preload by the selected donation `user_id` values.
- context-logic: `lib/philomena/donations.ex:31-40` contains the same
  `order_by`, `preload(:user)`, and `Repo.paginate` chain, called by
  `lib/philomena_web/controllers/admin/donation_controller.ex:8-12`.
- Delta: the query moved behind an authorization guard; authorization is
  outside SQL and the final read/count/preload shapes are unchanged.
- Index status: no index action. The listing has no filter predicate; an
  order-only index is not proposed without plan, cardinality, and workload
  evidence. The existing preload path is covered by
  `index_donations_on_user_id`.

### Per-user donation history (`show_user_donations/2`)

- Classification: `unchanged`.
- Master: `lib/philomena_web/controllers/admin/donation/user_controller.ex:9-15`
  uses Canary's persisted `load_resource` for `User` by `slug`, then
  `Repo.preload` with `[donations: :user]`. Canary's implementation issues a
  `users.slug = ?` member lookup, followed by the `donations.user_id` preload
  and nested donation-to-user primary-key preload.
- context-logic: `lib/philomena/donations.ex:66-76` builds
  `User |> where(slug: ^slug) |> preload(donations: :user) |> Loader.one`,
  called by `lib/philomena_web/controllers/admin/donation/user_controller.ex:8-17`.
- Delta: loading, not-found translation, and authorization moved into the
  context. The member predicate and all association preload predicates are
  unchanged. `lib/philomena/users/user.ex:40` has the same
  `has_many :donations, Donation` association in both refs, with no
  association `where` or ordering modifier.
- Index status: covered. `index_users_on_slug` is a unique B-tree,
  `index_donations_on_user_id` is an ordinary B-tree, and both target tables'
  primary keys cover the remaining member/preload lookups. No candidate is
  proposed.

### Donation creation (`create_donation/2`)

- Classification: `unchanged`.
- Master: `lib/philomena_web/controllers/admin/donation_controller.ex:21-29`
  calls `Donations.create_donation/1`; master
  `lib/philomena/donations.ex:52-56` builds the changeset and calls
  `Repo.insert`.
- context-logic: `lib/philomena/donations.ex:102-108` performs the same
  changeset-backed insert after authorization, called at
  `lib/philomena_web/controllers/admin/donation_controller.ex:15-28`.
- Delta: actor and write-access checks were added outside SQL. The insert
  target, foreign-key check, and absence of conflict/row-selection predicate
  are unchanged.
- Index status: no index action. `donations_pkey` and the users primary key
  support the same identity and foreign-key checks.

## Unchanged or non-index-relevant sites

- `lib/philomena/donations/donation.ex:9-27`: adding `@type t` and a default
  argument to `Donation.changeset/2` changes only the Elixir API. The schema
  has no query-affecting association condition.
- `lib/philomena/donations.ex:76`: direct construction of the blank donation
  changeset replaces `Donations.change_donation/1`; neither path issues SQL.
- `lib/philomena/data_exports/aggregator.ex:77`: the Donation entry is an
  export descriptor and does not issue a Donation query.
- The current donation fixture and context tests exercise the same context
  operations but add no production query shape.

## New, deleted, moved, or ambiguous sites

- Master's `Philomena.Donations.list_donations/0` at
  `lib/philomena/donations.ex:20-22` (`Repo.all(Donation)`) has no master
  caller and is deleted in context-logic. It is an unpaired legacy,
  unordered full-table collection, not a changed production workload.
- Master-only `get_donation!/1`, `update_donation/2`, `delete_donation/1`,
  and `change_donation/1` have no source callers. The first three are
  unpaired legacy APIs with no retained lookup/update/delete predicate;
  `change_donation/1` is a no-SQL changeset helper. No index recommendation
  is made for them.
- No additional Donation-owned query was found in workers, maintenance, or
  other context callers. OpenSearch and export serialization are outside this
  PostgreSQL audit.

--- Index and migration evidence ---

- `master` and `context-logic` have identical Donations table/index content in
  `priv/repo/structure.sql`; the branch's unrelated structure changes are a
  commission uniqueness change and an image-intensities FK cascade.
- The dump defines `donations_pkey` on `donations(id)`,
  `index_donations_on_user_id` on `donations(user_id)`, the donations foreign
  key to `users(id)`, `users_pkey`, and unique
  `index_users_on_slug` on `users(slug)`.
- `20200617111116_prod_schema_sync_2020_06_17.exs` establishes the unique
  users-slug index. `20200617113333_prod_schema_sync2.exs` only adjusts the
  donations sequence among this context's relevant history. The 202408 cleanup
  migration removes the obsolete `users.last_donation_at` column; no current
  Donation query uses it and no new index is needed.
- No migration adds, removes, or changes the Donations foreign-key index or
  the users-slug index between the refs. No `EXPLAIN` was run because every
  retained query pair is relationally unchanged and no changed access path
  lacks coverage.

## Follow-ups

- Correctness/order concern, not an index recommendation: the per-user
  `donations` association is unordered in both refs. If the page requires
  newest-first user history, make ordering explicit and separately audit a
  possible `(user_id, created_at DESC, id)` index. The admin listing also lacks
  a final unique tie-breaker after `created_at DESC, user_id ASC`; equal keys
  can move across pages, unchanged from master.
