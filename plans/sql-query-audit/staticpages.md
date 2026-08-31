# StaticPages SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 11 across both refs

--- files ---
AGENTS.md (provided repository instructions)
CONTEXT_STYLE.md
test/CONVENTIONS.md
test/support/fixtures/static_pages_fixtures.ex
test/philomena/static_pages_test.exs
test/philomena_web/controllers/page_controller_test.exs
test/philomena_web/controllers/page/history_controller_test.exs
priv/repo/structure.sql
priv/repo/migrations/20240818182358_cleanup.exs
lib/philomena/static_pages.ex
lib/philomena/static_pages/static_page.ex
lib/philomena/static_pages/version.ex
lib/philomena_web/controllers/page_controller.ex
lib/philomena_web/controllers/page/history_controller.ex
lib/philomena_web/stats_updater.ex
lib/philomena/loader.ex
deps/canary/lib/canary/plugs.ex
deps/ecto/lib/ecto/repo/queryable.ex

no SQL shape changes found.

## Changed shapes

None. The context-logic changes move the page listing, slug loader, revision
history query, and statistics upsert into `Philomena.StaticPages`; their final
PostgreSQL relational shapes are unchanged.

## Unchanged or non-index-relevant sites

- `list_pages/1`, current `lib/philomena/static_pages.ex:21-23,76-80`, is the
  moved counterpart of Canary's master `:index` handling for
  `lib/philomena_web/controllers/page_controller.ex:8-11`. Both issue an
  unordered full-row collection query on `static_pages` with no filter, join,
  grouping, pagination, or preload. Current authorization runs before the
  query; master loaded the collection before authorizing. That changes when
  the same query executes, not its SQL shape.
- `show_page/2`, `edit_page/2`, and `update_page/3` use
  `StaticPage |> where(slug: ^slug) |> Loader.one_and_authorize/3` at
  `lib/philomena/static_pages.ex:25-29,100-101,204-207,227-229`. Their master
  counterparts were Canary `Repo.get_by(StaticPage, slug: value)` member
  lookups from the `load_and_authorize_resource` plug at
  `lib/philomena_web/controllers/page_controller.ex:8`.
  `Repo.get_by/3` is implemented as a `Repo.one` over the same equality
  predicate (`deps/ecto/lib/ecto/repo/queryable.ex:87-89,503-505`), so the
  normalized shape is `static_pages WHERE slug = :slug`, selecting one full
  row, with no order or join. The unique slug index covers it.
- The page part of `list_page_history/2` at
  `lib/philomena/static_pages.ex:119-128` is the same slug member lookup
  previously performed by the history controller's required Canary loader at
  `master:lib/philomena_web/controllers/page/history_controller.ex:10-13`.
  The history query itself remains `static_page_versions WHERE
static_page_id = :page_id`, selecting full version rows, preloading users by
  `user_id`, and ordering by `created_at DESC, id DESC`, at current
  `lib/philomena/static_pages.ex:121-126` and master
  `lib/philomena_web/controllers/page/history_controller.ex:15-20`.
  There is no limit, offset, additional visibility predicate, or parent join.
  The `Version` schema association at `lib/philomena/static_pages/version.ex:10-20`
  is unchanged and has no association `where` or order clause.
- `create_page/2` and `update_page/3` retain the same write shapes as the
  master context's `create_static_page/2` and `update_static_page/3`:
  inserts into `static_pages` and `static_page_versions`, and an update of the
  loaded `static_pages` row by its primary key. Current
  `Philomena.Multi` steps are at `lib/philomena/static_pages.ex:33-57`; master
  `Ecto.Multi` steps are at `master:lib/philomena/static_pages.ex:54-91`.
  Switching transaction wrappers and translating results does not alter a
  row-selection predicate, conflict target, join, or lock.
- `upsert_statistics_page/1` at `lib/philomena/static_pages.ex:255-271` is a
  direct move from `master:lib/philomena_web/stats_updater.ex:51-64`.
  Both issue one `INSERT ... ON CONFLICT (slug) DO UPDATE`, replacing only
  `body` and `updated_at`; the `slug` conflict target is unchanged. The
  surrounding statistics calculation moved to `SiteStatistics`, but those
  other-context aggregates are outside this StaticPages audit.
- `StaticPage` at `lib/philomena/static_pages/static_page.ex:9-21` has no
  query-affecting association or changeset lookup. The added `t` type and
  current schema metadata do not change SQL. The fixture's direct
  `Philomena.Multi` inserts in
  `test/support/fixtures/static_pages_fixtures.ex:29-36` are test setup, not a
  production workload.

## New, deleted, moved, or ambiguous sites

- Master `Philomena.StaticPages.get_static_page!/1` at
  `master:lib/philomena/static_pages.ex:40` was an uncalled primary-key member
  lookup and is removed. No retained caller depended on it, so this is an
  unpaired legacy API rather than a changed workload; `static_pages_pkey`
  covered the lookup.
- Master `Philomena.StaticPages.delete_static_page/1` at
  `master:lib/philomena/static_pages.ex:106-108` was also uncalled in the
  inspected source tree and is removed. Its standalone shape was
  `DELETE FROM static_pages WHERE id = :id`, covered by the primary key; no
  current StaticPages delete workload was found.
- `new_page/1`, `change_static_page/1`, and the controller rendering changes
  issue no SQL. Authorization and write-access checks are application-level
  predicates; they do not add PostgreSQL visibility filters. The current
  history loader authorizes the page before fetching versions, whereas the
  master history route did not add a separate page authorization check, but
  StaticPage `:show` is public and the SQL predicate remains the same.
- No StaticPages-owned worker, maintenance query, `Repo.preload` follow-up
  beyond the history user preload, `delete_all`, `update_all`, aggregate, or
  locking query was found. No ambiguous query counterpart remains.

## Index and migration evidence

- `priv/repo/structure.sql:1644-1698,3057-3070,4195-4216` is unchanged for
  these tables between `master` and `context-logic` (the overall dump differs
  only for unrelated later migrations and dump metadata). It contains:
  `static_pages_pkey`, unique B-tree `index_static_pages_on_slug`, unique
  B-tree `index_static_pages_on_title`, B-tree
  `index_static_page_versions_on_static_page_id`, and B-tree
  `index_static_page_versions_on_user_id`.
- The static-page foreign keys to `users` and `static_pages` are present in
  both dumps. The version history filter is therefore covered by
  `index_static_page_versions_on_static_page_id`, and its user preload is
  covered by `index_static_page_versions_on_user_id`; the nested user lookup
  uses `users_pkey`. Slug loading and the upsert conflict target are covered by
  the unique slug index. Page updates use the primary key.
- `priv/repo/migrations/20240818182358_cleanup.exs:295-300` is the only
  migration mentioning these tables; it normalizes `created_at` types and
  introduces no query index or constraint change. No StaticPages creation or
  index migration exists in the repository migration history. No index
  candidate is proposed and no representative EXPLAIN was needed for an
  unchanged, already-covered shape.

## Follow-ups

- Correctness/determinism: the history order has the explicit stable
  `created_at DESC, id DESC` tie-breaker in both refs, so no ordering regression
  or new order-supporting index is indicated.
- The statistics upsert relies on the unique `slug` index and has no changed
  conflict target. Keep that index in place; do not add a duplicate
  `static_pages(slug)` index.
- Shared-query review: `Philomena.Loader.one_and_authorize/3` is a shared
  authorization/loading helper and should be linked from `shared.md`; this
  report treats its StaticPages use as the unchanged slug member lookup.
