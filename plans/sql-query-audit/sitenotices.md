# SiteNotices SQL shape audit

Refs: master -> context-logic  
Status: complete

--- status ---

No SQL shape changes found. The context-logic work moves the administrative
listing into `Philomena.SiteNotices`, replaces Canary's member loader with the
shared `Philomena.Loader`, and adds authorization/result handling; it does not
change the relational access requirements for SiteNotices.

--- report dir ---

Query sites inspected: 8 source-level sites covering the active public read,
the administrative page, member loads for edit/update/delete, and insert,
update, and delete writes. Callers inspected include
`PhilomenaWeb.SiteNoticePlug`, the admin SiteNotice controller, and the
SiteNotice schema.

## Changed shapes

None — no SQL shape changes found.

## Unchanged or non-index-relevant sites

### Active public notices

- Master: `Philomena.SiteNotices.active_site_notices/0`
  (`lib/philomena/site_notices.ex:20-27`): `site_notices`, select full rows,
  fixed `live = true`, `start_date < now`, `finish_date > now`, ordered by
  `start_date DESC`, `Repo.all`.
- context-logic: same operation (`lib/philomena/site_notices.ex:37-45`) and
  same strict active-window predicates and ordering. It remains called by
  `PhilomenaWeb.SiteNoticePlug.call/2` (`lib/philomena_web/plugs/site_notice_plug.ex:19-23`).
- Delta: function/documentation movement only; no filters, joins, grouping,
  pagination, preload, or ordering change.
- Index status: no index action.
- Evidence: both refs contain the same ordinary B-tree
  `index_site_notices_on_start_date_and_finish_date` on
  `(start_date, finish_date)` (`priv/repo/structure.sql:4157-4160`). Its
  leading `start_date` column supports the range/order access path; the
  `finish_date` and `live` predicates do not create a new shape in this diff.
- Confidence: high

### Administrative listing

- Master: `PhilomenaWeb.Admin.SiteNoticeController.index/2`
  (`lib/philomena_web/controllers/admin/site_notice_controller.ex:12-18`):
  full-row collection page from `site_notices`, ordered by `start_date DESC`,
  with `Repo.paginate(scrivener)`.
- context-logic: `Philomena.SiteNotices.list_site_notices/2`
  (`lib/philomena/site_notices.ex:65-73`), called by the controller
  (`lib/philomena_web/controllers/admin/site_notice_controller.ex:8-12`):
  the same full-row page, ordering, and pagination. Authorization happens
  before the query and adds no SQL predicate.
- Delta: controller-to-context movement and actor authorization; no
  filter/join/order/group/pagination/preload change.
- Index status: covered.
- Evidence: the existing `(start_date, finish_date)` index covers the leading
  `start_date DESC` ordering. No separate index for the unchanged listing is
  warranted.
- Confidence: high

### Member load and writes

- Master: the admin controller's
  `load_and_authorize_resource, model: SiteNotice, except: [:index]`
  (`lib/philomena_web/controllers/admin/site_notice_controller.ex:9-10`)
  used Canary's `repo.get_by(SiteNotice, %{id: conn.params["id"]})` for
  edit/update/delete (Canary implementation `deps/canary/lib/canary/plugs.ex:365-389`).
  This is a single-row primary-key lookup; new/create loaded no row.
- context-logic: `load_site_notice/3`
  (`lib/philomena/site_notices.ex:20-22`) delegates to
  `Loader.fetch_and_authorize/5`; valid IDs use `Repo.get` in
  `lib/philomena/loader.ex:84-89,115-126`, producing the same single-row
  `site_notices.id = $1` lookup. Invalid/out-of-range IDs now short-circuit in
  `IntegerId.parse/1` before SQL, which is a validation/error-handling change,
  not an index-relevant shape change.
- `create_site_notice/2` still performs an insert
  (`lib/philomena/site_notices.ex:118-124`); `update_site_notice/3` and
  `delete_site_notice/2` still operate on the already loaded row
  (`lib/philomena/site_notices.ex:171-177,198-202`). Their write predicates
  remain primary-key based and unchanged in access requirements.
- Delta: `get_by` versus `get`, centralized loading, and actor-first
  authorization; no changed lookup column, join, preload, or write target
  predicate.
- Index status: covered.
- Evidence: `site_notices_pkey` on `(id)` exists in both structure dumps
  (`priv/repo/structure.sql:3038-3042`). The `user_id` index also remains
  present (`priv/repo/structure.sql:4163-4167`), although no inspected
  SiteNotice operation preloads or joins `user`.
- Confidence: high

## New, deleted, moved, or ambiguous sites

- `list_site_notices/2` is a moved query: its master counterpart is the admin
  controller's inline `Repo.paginate` query. It is paired above.
- The old `get_site_notice!/1` context API is deleted and had no callers found
  outside its definition. It was a primary-key `Repo.get!` member lookup; the
  current controller paths are paired with the Loader member lookup above.
- `change_site_notice/1` was replaced by `new_site_notice/1` and the
  changeset portion of `edit_site_notice/2`; these are changeset construction
  and do not issue SQL.
- No ambiguous SiteNotice query, association preload query, worker query, or
  maintenance query was found.

## Follow-ups

- No SiteNotices index recommendation or migration follow-up is supported by
  this comparison. A partial/specialized index involving `live` would require
  representative `EXPLAIN` output and workload/table-cardinality evidence;
  the query shape is unchanged and the existing date index is already present.
- Shared Loader behavior is owned by the shared audit; this report only records
  its SiteNotice member-lookup consumer.
