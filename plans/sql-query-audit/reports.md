# Reports SQL shape audit

Refs: master -> context-logic  
Status: complete

--- status ---

Query sites inspected: 31 (Reports context and nested modules, the former
admin/user report controllers, report-target call sites, report workers and
maintenance callbacks, schema associations, and the report indexes/migration
history).

## Changed shapes

### `Reports.list_reports/3`: staff index assembly

- Master: `lib/philomena_web/controllers/admin/report_controller.ex:23-115`,
  `load_reports/2`; the primary result is an OpenSearch request (excluded from
  SQL audit). The no-query branch additionally executes two SQL collection
  pages, each `reports WHERE open = true AND admin_id = $1` or
  `reports WHERE open = true AND system = true`, ordered by `created_at DESC`,
  with association preloads.
- context-logic: `lib/philomena/reports.ex:250-283`,
  `list_reports/3`; the OpenSearch request has the same sort and the same
  report/target preloads. The no-query branch keeps the same two SQL shapes in
  `Repo.all/1` at `:272`, using the shared `open_report_query/0` relation.
- Delta: SQL relational shape unchanged; the former controller query was moved
  into the context and preloads were composed into the same relation. The
  OpenSearch query body is not PostgreSQL evidence.
- Index status: covered | no index action
- Evidence: `index_reports_on_admin_id` (`reports(admin_id)`),
  `reports_system_index` (`reports(system) WHERE system = true`),
  `index_reports_on_open` and `index_reports_on_created_at` exist in
  `priv/repo/structure.sql:4129-4156,4703-4709` on both refs. No SQL plan was
  run because this is an unchanged, low-complexity branch and local workload
  evidence was unavailable.
- Confidence: high

### `Reports.show_report/2`: staff member lookup and target preloads

- Master: `lib/philomena_web/controllers/admin/report_controller.ex:16-21,84-90`
  loads the report through `load_and_authorize_resource` by primary key, then
  `Reports.preload_targets/1` issues one report-target preload set. The report
  itself is a member lookup `reports WHERE id = $1`.
- context-logic: `lib/philomena/reports.ex:56-60,301-305`,
  `report_query/1` + `show_report/2`; `Loader.fetch_and_authorize/4` performs
  the same primary-key member lookup, with default and target preloads attached
  before execution.
- Delta: moved/centralized query; no changed base filter or join. Target
  preloads remain association queries keyed by report foreign keys. Authorization
  is now explicitly part of the context API, but does not add a SQL predicate
  to the report lookup.
- Index status: covered | no index action
- Evidence: `reports_pkey` covers `id`; all target foreign-key preload indexes
  are present as partial B-trees (`reports_*_id_index`) in
  `priv/repo/structure.sql:4654-4701` on both refs.
- Confidence: high

### `Reports.create_report/3`: submission-limit checks

- Master: `lib/philomena_web/controllers/report_controller.ex:35-42,63-97`,
  `too_many_reports_user?/1` and `too_many_reports_ip?/1`; user branch is
  `reports WHERE user_id = $1 AND state IN ('open','in_progress') COUNT(*)`,
  and IP branch is the same shape with `ip = $1`. The insert itself has no row
  selection predicate.
- context-logic: `lib/philomena/reports.ex:87-108,392-419`,
  `open_report_count/2`, `ensure_report_limit/2`, and `create_report/3`; the
  two count shapes are identical. A user primary-key lock is also added via
  `Multi.lock_one/3` at `:406` (`users WHERE id = $1 FOR UPDATE`), and an
  advisory lock is added for the IP quota.
- Delta: changed, index-relevant only by addition of a PK locking query; the
  quota predicates are unchanged and moved from the controller. The added user
  lock is covered by `users_pkey`; the advisory lock is not a PostgreSQL row
  access path.
- Index status: covered | no index action
- Evidence: `users_pkey` covers the new lock. Existing
  `index_reports_on_user_id` covers the user equality and
  `reports(ip)` has no index; however the IP count shape pre-existed unchanged,
  so this audit does not promote a new index without representative plans,
  cardinality, and workload frequency.
- Confidence: high

### `Reports.create_report_claim/2`, `delete_report_claim/2`, and

`create_report_close/2`: locked moderation transitions

- Master: `lib/philomena/reports.ex:251-288` exposed `claim_report/2`,
  `unclaim_report/1`, and `close_report/2`; callers passed an already-loaded
  `%Report{}` and each operation issued only an `UPDATE reports ... WHERE id =
$1` through `Repo.update/1` (no context lookup or row-lock query).
- context-logic: `lib/philomena/reports.ex:110-117,456-485,502-531,548-579`,
  `put_lock_report/4` plus the three moderation APIs; each first executes
  `reports WHERE id = $1 FOR UPDATE`, then updates that row through a changeset.
- Delta: changed, index-relevant due to the new locking/member lookup query;
  the update target remains the primary key. The new changeset validation adds
  in-memory open/claimed checks, not an SQL predicate. This is also a semantic
  concurrency/correctness improvement because authorization and state are
  evaluated on the locked row.
- Index status: covered | no index action
- Evidence: `reports_pkey` covers the lock and update target. No composite
  state/admin index is needed for these ID-based operations.
- Confidence: high

### `Reports.put_close_reports/4`: bulk close against a target

- Master: `lib/philomena/reports.ex:101-146,155-160`,
  `close_report_query/2` and `close_reports/2`; update shape is
  `UPDATE reports SET open=false,state='closed',admin_id=$1,updated_at=$2
WHERE <one target FK> = $3 AND open=true`, returning the affected `id`s.
- context-logic: `lib/philomena/reports.ex:130-148,581-600`,
  `close_report_query/2` and `put_close_reports/4`; the same dynamic target-FK
  equality plus `open=true` predicate and returned IDs are composed into
  `Multi.update_all/4`, with reindexing after commit.
- Delta: unchanged relational shape; moved into a private query builder and
  transaction composition API. The guard now restricts the dynamic target
  column to the seven reportable foreign keys; this narrows trusted API input
  but does not alter valid query shapes.
- Index status: covered | no index action
- Evidence: partial indexes on `comment_id`, `commission_id`,
  `conversation_id`, `gallery_id`, `image_id`, `post_id`, and
  `reported_user_id`, each `WHERE ... IS NOT NULL`, cover the equality side of
  every valid branch. The `open=true` residual predicate is unchanged; no
  index recommendation is made without plans. These indexes originate in
  `priv/repo/migrations/20260719123608_add_reportable_association_to_reports.exs:45-51`
  and are present in both refs’ structure dumps.
- Confidence: high

### `Reports.wipe_user_attribution!/3`: user wipe maintenance update

- Master: no Reports-context counterpart. User erasure was not implemented in
  the Reports context; `lib/philomena/users/user_wipe.ex` had no report wipe
  call on master. This is a genuinely new persistence workload, not a moved
  query.
- context-logic: `lib/philomena/reports.ex:658-669`,
  `wipe_user_attribution!/3`; batch selection is `reports WHERE user_id = $1`,
  followed by batched `UPDATE reports SET ip=$2,fingerprint=$3` for selected
  rows. The batch helper adds its normal keyset/limit mechanics.
- Delta: new query site and new update workload. It is called by
  `Philomena.Users.UserWipe` at `lib/philomena/users/user_wipe.ex:44`.
- Index status: covered | no index action
- Evidence: `index_reports_on_user_id` exists in both structure dumps and
  covers the selection. No separate index is justified for a maintenance-only
  equality update; the update columns are not row-selection columns.
- Confidence: high

## Unchanged or non-index-relevant sites

- `Reports.count_open_reports/1`, `lib/philomena/reports.ex:172-198`, is the
  same aggregate `COUNT(*) FROM reports WHERE open=true` as the former
  controller/context implementation (`master` `reports.ex:25-48`), with the
  authorization check moved into the context. Existing `index_reports_on_open`
  covers it.
- `Reports.list_user_reports/2`, `lib/philomena/reports.ex:200-228`, is the
  former `PhilomenaWeb.ReportController.index/2` query moved verbatim:
  `reports WHERE user_id=$1 ORDER BY created_at DESC` with rule and target
  preloads and pagination. Existing `index_reports_on_user_id` and
  `index_reports_on_created_at` cover the constituent access paths.
- `Reports.report_query/1` (`:56-60`) and `Report.target_preloads/0`
  (`lib/philomena/reports/report.ex:62-75`) only define report and target
  association preloads. The target schemas’ `has_many :reports` associations
  (`images/image.ex:52`, `comments/comment.ex:17`, `posts/post.ex:17`,
  `commissions/commission.ex:16`, `conversations/conversation.ex:17`,
  `galleries/gallery.ex:19`, `users/user.ex:45`) have no association `where`
  clause that changes preload SQL.
- `Reports.put_create_system_report/5`, `lib/philomena/reports.ex:602-646`,
  replaces `create_system_report/3`: both are inserts with no row-selection
  predicate. `Reports.create_report/3` likewise retains an insert after target
  loading; target loading is delegated to owning contexts and is outside this
  report’s SQL ownership.
- `Reports.convert_legacy_report!/3` (`lib/philomena/reports.ex:648-656`) and
  `Reports.LegacyConverter.convert_reports!/0`
  (`lib/philomena/reports/legacy_converter.ex:38-48`) preserve the old
  `reports` batch scan with `rule` preload and per-row PK update. The module
  move does not change SQL shape.
- `Reports.perform_reindex/2`, `lib/philomena/reports.ex:714-731`, preserves
  the worker selection `reports WHERE field(column) IN (...)`; current
  association preloads are attached to the relation rather than performed by
  a separate explicit preload pass. This is unchanged SQL access behavior;
  search indexing requests are excluded.
- `Reports.user_name_reindex/2` and `Reports.SearchIndex.user_name_update_by_query/2`
  (`lib/philomena/reports.ex:671-686`, `reports/search_index.ex:73-94`) issue
  OpenSearch update-by-query requests only, not PostgreSQL queries.
- `Report` changesets (`reports/report.ex:75-181`) and `ReportForm`,
  `QueryForm`, and `ReportPage` contain no additional SQL. `QueryBuilder`
  (`reports/query_builder.ex:17-39`) builds OpenSearch query/sort data and is
  excluded by the audit plan.
- Former `list_reports/0`, `get_report!/1`, `update_report/2`, `delete_report/1`,
  `reindex_report/1`, and explicit `preload_targets/*` APIs were removed or
  absorbed into the context API. Their SQL either has the counterparts above
  or is a PK write/member lookup covered by the same primary key; no distinct
  changed shape remains.

## New, deleted, moved, or ambiguous sites

- The old admin report collection’s primary result was OpenSearch, not SQL.
  It is replaced by `Reports.list_reports/3`; only the two unchanged SQL
  supplemental collections are included above.
- `Reports.show_report/2` is a moved/expanded authorization boundary around the
  former controller loader. The exact generated SQL for `Loader.fetch_and_authorize/4`
  was not emitted because the app container/database was not needed for this
  read-only source audit; source and PK/index evidence make the shape clear.
- `Reports.load_report_target/2` dispatches to Images, Comments, Posts, Users,
  Commissions, Conversations, and Galleries (`reports.ex:62-85`). Those are
  cross-context visibility/member queries and should be canonicalized by their
  owning context reports/shared findings, rather than duplicated here.
- `Reports.mod_notes/3` delegates to `ModNotes.list_for_target/3`
  (`reports.ex:307-329`); its report-target query belongs to the ModNotes
  context/shared audit and is not duplicated here.
- `Reports.indexing_preloads/0` (`reports.ex:688-712`) contains nested target
  preload queries used by the index worker. They have no schema `where` clauses
  and are unchanged; OpenSearch serialization remains out of scope.

## Follow-ups

- No changed Reports SQL shape requires a new index. The pre-existing IP quota
  count (`reports WHERE ip=$1 AND state IN (...)`) has no evident `ip` index,
  and the user quota count may benefit from `(user_id, state)`; both are
  unchanged workloads. Before proposing either, collect representative
  `EXPLAIN (FORMAT JSON)` plans plus table/cardinality and submission-rate
  evidence. A partial `(ip) WHERE state IN ('open','in_progress')` and/or a
  composite `(user_id, state)` are possibilities only, not recommendations.
- The new `wipe_user_attribution!/3` is covered by `user_id`; verify batch
  helper plans on production-sized data if erasure latency becomes material.
- Cross-context target-loading and ModNotes queries should be linked to their
  owning reports in coordinator synthesis. No correctness issue was found in
  the Reports-owned SQL beyond the intended locked moderation transition.
