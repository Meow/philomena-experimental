# Commissions SQL shape audit

Refs: master -> context-logic  
Status: complete  
Query sites inspected: 14 logical sites (including the directory's optional
filter branches, association preloads, counter updates, report close update,
and the site-statistics aggregates)

## Changed shapes

### Public commission directory search (`list_commissions/3`)

- Master: `lib/philomena/commissions/query_builder.ex:43-66`, called by
  `lib/philomena/commissions.ex:128-130` via the index controller. Base table is
  `commissions`; inner join `commission_items` on `commission_items.commission_id
= commissions.id`; inner join `user_ips` on `user_ips.user_id =
commissions.user_id`; fixed filters are `commissions.open = true`,
  `commissions.commission_items_count > 0`, and `user_ips.updated_at >= now -
2 weeks`. Optional branches add item `base_price` inclusive range, item
  `item_type =`, commission `categories @>`, or an `OR` of
  `ILIKE '%keywords%'` on `information`/`will_create`. Group by commission ID,
  order by `random()`, then preload user/awards and items/example images.
- context-logic: `lib/philomena/commissions/query_builder.ex:43-70`, invoked
  by `lib/philomena/commissions.ex:90-107` as `list_commissions/3`. Same base,
  joins, optional filters, grouping, random ordering, pagination, and
  preloads, plus an inner join `users` on `users.id = commissions.user_id` and
  fixed filter `users.deleted_at IS NULL`.
- Delta: `users` join and active-user predicate are a changed, index-relevant
  relational shape. The keyword sanitization rewrite is semantically
  equivalent: both refs issue leading/trailing-wildcard `ILIKE`; it is not a
  shape change. `QueryForm` return data and invalid-parameter handling do not
  alter SQL.
- Index status: no index action
- Evidence: `users.id` is the primary key; current `commissions.user_id` is
  uniquely indexed (`index_commissions_on_user_id`), `commission_items` has
  `index_commission_items_on_commission_id` and `..._on_item_type`, and
  `user_ips` has `(user_id, updated_at DESC)`. `users.deleted_at` is not indexed,
  but a standalone/partial deleted-at index would not improve this PK join in
  the expected directory shape. `open` has its existing B-tree index. The
  `random()` ordering, wildcard `ILIKE`, array containment, grouping, and
  pagination cannot be addressed by a generic additional B-tree. No EXPLAIN
  was run because no database plan was needed to identify a missing mandatory
  access path.
- Confidence: high

### Active profile commission load and listing preloads

- Master: `lib/philomena_web/controllers/profile/commission_controller.ex:11-23`
  and `lib/philomena_web/controllers/profile/commission/item_controller.ex:11-23`
  use Canary's `load_resource` to load `users` by unique `slug`, preloading
  `verified_links` and the `commission` association. The association follow-up
  is a member collection query on `commissions.user_id = users.id`, with the
  nested sheet-image, user/awards, and items/example-image preloads. The
  concrete generic plug implementation is external to this repository.
- context-logic: `lib/philomena/users.ex:308-312` (`Users.load_profile/3`)
  loads `users` with `users.slug = ^slug AND users.deleted_at IS NULL`, then
  `lib/philomena/commissions.ex:34-39` loads `commissions` with
  `commissions.user_id = ^user_id` and the explicit commission preload graph.
  `show_commission/2`, `edit_commission/2`, `update_commission/3`,
  `delete_commission/2`, and report-target loading share this path.
- Delta: the old controller-owned user load/preload was moved into context
  APIs and now explicitly adds `users.deleted_at IS NULL`; the commission
  member lookup remains user-scoped and is now followed by the same explicit
  preload graph. The moved user query is shared with Profiles and should be
  canonicalized in `shared.md`/the Users report.
- Index status: covered
- Evidence: `index_users_on_slug` covers the profile lookup,
  `index_commissions_on_user_id` covers the commission lookup (unique in
  context-logic), and the user/commission primary keys cover nested belongs-to
  preloads. The current unique index was introduced by
  `priv/repo/migrations/20260806180557_unique_commission_per_user.exs`; before
  that migration, both refs had the same ordinary `user_id` access path.
- Confidence: high

### Ordered commission-items association preload

- Master: `lib/philomena/commissions/commission.ex:9-12` declares
  `has_many :items` without an association order; the profile controller then
  performs an in-memory `Enum.sort/2` at
  `lib/philomena_web/controllers/profile/commission_controller.ex:33-35`.
  Directory preloads have no item order beyond the database's unspecified row
  order.
- context-logic: `lib/philomena/commissions/commission.ex:12-16` declares
  `has_many :items, preload_order: [asc: :base_price, asc: :id]`. This affects
  the item preload issued by `load_profile_commission/3` and the directory
  preload in `QueryBuilder.commission_search_query/0` (`query_builder.ex:67-70`):
  `SELECT commission_items ... WHERE commission_id IN (...) ORDER BY
base_price ASC, id ASC`.
- Delta: item preload SQL gained an `ORDER BY base_price ASC, id ASC`; the
  profile-side in-memory sort was removed. This is index-relevant for large
  listings, although the directory's parent query still uses random ordering.
- Index status: reviewed and rejected (human production review)
- Evidence: current `index_commission_items_on_commission_id` covers the
  equality predicate, but neither ref has `(commission_id, base_price, id)`.
  A possible follow-up is `CREATE INDEX ... ON commission_items
(commission_id, base_price, id)` to support the equality-plus-ordering
  preload. The focused review rejects it at p99 item count 14; the existing
  foreign-key index and small fan-out make the sort cheaper than maintaining a
  second ordering index.
- Confidence: high

## Unchanged or non-index-relevant sites

- `QueryBuilder.maybe_filter_price/2` (`query_builder.ex:73-79`),
  `maybe_filter_item_type/2` (`:82-89`), `maybe_filter_categories/2`
  (`:91-98`), and `maybe_filter_keywords/2` (`:100-109`) retain the same
  optional branches on both refs. Price is an inclusive two-sided range;
  item type is equality; categories use array containment; keywords use the
  leading-wildcard `OR ILIKE` shape. These are included in the changed
  directory shape above, but no separate index recommendation is justified.
- `create_commission/3` (`commissions.ex:194-203`) versus master
  `create_commission/2` (`master commissions.ex:44-48`): insert-only changeset;
  no row-selection predicate. The current unique `user_id` constraint changes
  conflict/error enforcement, not the query shape.
- `update_commission/3` (`commissions.ex:245-252`) versus master
  `update_commission/2` (`master commissions.ex:62-66`): Ecto updates an
  already-loaded row by primary key; unchanged PK target.
- `create_item/3` (`commissions.ex:331-355`) versus master
  `create_item/2` (`master commissions.ex:173-194`): the insert and counter
  update remain the same. Counter update shape is `UPDATE commissions SET
commission_items_count = commission_items_count + 1 WHERE id = ?`; covered
  by the commissions primary key.
- `update_item/4` (`commissions.ex:404-412`) versus master
  `update_item/2` (`master commissions.ex:208-212`): update by loaded item
  primary key; unchanged.
- `delete_item/3` (`commissions.ex:427-450`) versus master
  `delete_item/1` (`master commissions.ex:226-236`): item delete by primary key
  plus unchanged counter decrement `WHERE commissions.id = ?`; covered by
  primary key. The transaction wrapper/result mapping is not SQL shape.
- `delete_commission/2` (`commissions.ex:270-285`) versus master
  `delete_commission/2` (`master commissions.ex:80-97`): the commission delete
  is by loaded primary key. The report-closing `UPDATE` is delegated to the
  shared `Reports.put_close_reports/4`/`close_report_query` path; its
  commission-target predicate belongs in the Reports/shared audit. The new
  `has_many :reports` association and FK behavior do not add a Commissions
  query shape here.
- `Repo.preload(user, @profile_preloads)` (`commissions.ex:107`) and the
  post-insert `Repo.preload(commission, @commission_preloads)` (`:202`) issue
  ordinary association queries on existing foreign keys. Nested sources,
  tags, aliases, awards, and badges are owned by their respective contexts;
  the item association's new order is the only preload delta identified here.
- `Philomena.SiteStatistics.commissions/0` (`lib/philomena/site_statistics.ex:179-184`)
  has unchanged aggregates: `COUNT(commissions.id) WHERE open = true` and
  `COUNT(commission_items.id)`. The former can use the existing `open` index
  (subject to aggregate planner choice); the latter is a full-table count with
  no useful selective predicate. This supporting workload is recorded here,
  not treated as a context-logic delta.

## New, deleted, moved, or ambiguous sites

- Master's public `get_commission!/1` and `get_item!/1` (`master
commissions.ex:30` and `:159`) have no direct current counterparts. They
  were replaced by actor/profile-scoped loaders (`show_commission/2` and
  `load_commission_item/2`), not silently removed workloads. Their former
  single-table PK lookups were covered by primary keys.
- Profile commission and item CRUD queries moved from controller plugs and
  direct `Repo.get_by!(Item, commission_id: ..., id: ...)` at
  `master lib/philomena_web/controllers/profile/commission/item_controller.ex:57-60,
:73-78, :94-99` into `Commissions.load_profile_commission/3` and
  `load_commission_item/2` (`commissions.ex:34-45`). The item current shape is
  `WHERE id = ? AND commission_id = ?` plus a `commission -> user` preload;
  PK and `index_commission_items_on_commission_id` cover it. The explicit
  preload is needed for the controller's returned item and is not a missing
  index candidate.
- `Reports.new_report/2` now reaches `Commissions.load_report_target/2`
  (`commissions.ex:144-148`) instead of relying on controller-loaded profile
  state. This is the same active-profile/commission lookup above; report
  query ownership and the report-target preload remain in the Reports/shared
  audit.
- No worker or maintenance module performs a distinct commission row query.
  `DataExports.Aggregator` only declares exported associations, and
  `SiteStatistics` is the aggregate workload listed above.

## Follow-ups

- Confirm the active-user directory join's runtime plan on production-like
  cardinalities; do not add a `deleted_at` index solely because the predicate
  is new.
- Run `EXPLAIN (FORMAT JSON)` for the ordered item preload before accepting
  `(commission_id, base_price, id)`; assess listing cardinality and write cost.
- Canonicalize the shared `Users.load_profile/3` query and nested user/link
  preloads in `shared.md` and the Users/Profiles reports. Reconcile the
  Reports `close_report_query` finding there rather than duplicating it.
- The old generic Canary query implementation is external, so exact SQL for
  the master profile loader could not be generated from repository source;
  the semantic counterpart is established from its `model: User`, `id_field:
"slug"`, `persisted: true`, and preload options.
