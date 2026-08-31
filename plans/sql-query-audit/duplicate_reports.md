# DuplicateReports SQL shape audit

Refs: master -> context-logic  
Status: complete

Query sites inspected: 8

--- files ---

- `lib/philomena/duplicate_reports.ex`
- `lib/philomena/duplicate_reports/duplicate_report.ex`
- `lib/philomena/duplicate_reports/query_builder.ex`
- `lib/philomena/duplicate_reports/transaction_workflow.ex`
- `lib/philomena/duplicate_reports/search_query.ex`
- `lib/philomena/duplicate_reports/comparison.ex`
- `lib/philomena_web/controllers/duplicate_report_controller.ex`
- `lib/philomena_web/controllers/image/reporting_controller.ex`
- `lib/philomena_web/controllers/duplicate_report/{accept,accept_reverse,claim,reject}_controller.ex`
- `lib/philomena/images.ex` (caller of `put_reject_image_reports/3`)
- `priv/repo/structure.sql`

## Findings

### Perceptual matching / reverse-image search — changed, index-relevant

Both refs use an `images` inner join to the one-row-per-image `image_intensities`
table on `image_intensities.image_id = images.id`, with four inclusive intensity
ranges, an inclusive `images.image_aspect_ratio` range, distance-expression
ordering, and a caller-controlled limit. `generate_reports/1` and reverse search
are the two callers. `context-logic` factors this into `duplicate_query/3` and
adds a deterministic `images.id ASC` tie-breaker to the distance ordering. The
automated-report branch also adds `images.hidden_from_users = false`; reverse
search applies the same predicate for ordinary actors but omits it for actors
authorized to see hidden images. The hidden-image predicate is a semantic
visibility change as well as an access-path change.

The existing `image_intensities_index (nw, ne, sw, se)` can constrain the
leading intensity ranges; `index_image_intensities_on_image_id (image_id)` is
unique and covers the join. `images.id` is the primary key. There is no index on
`images.image_aspect_ratio` or `images.hidden_from_users`. The computed distance
ordering, multiple range predicates, and optional visibility branch do not justify
a generic new B-tree from source inspection. No index recommendation without a
representative `EXPLAIN` and workload/cardinality evidence.

### Duplicate-report index page — changed, index-relevant

On `master`, the controller builds `duplicate_reports` with
`state IN (^states)`, preloads the report associations, and orders by
`created_at DESC`. On `context-logic`, `QueryBuilder` issues the same collection
query but orders by `created_at DESC, id DESC`; invalid state input instead
produces a deliberately empty `WHERE FALSE` page. The latter is an error branch,
not a workload requiring an index. The added ID tie-breaker changes the ordered
shape and makes pagination deterministic.

`index_duplicate_reports_on_state_filtered (state)` (partial for open/claimed),
`index_duplicate_reports_on_state (state)`, and
`index_duplicate_reports_on_created_at (created_at)` already cover the principal
filters/order. A composite `(created_at DESC, id DESC)` could avoid sorting ties,
but there is no plan or workload evidence that its write/storage cost is useful;
do not add it based on this audit alone. The associated preload queries are
unchanged in relational requirements and are covered by the existing foreign-key
indexes (or belong in the shared preload/visibility audit).

### Report involving one image — changed, likely not index-relevant

The old image-reporting controller queried `duplicate_reports` with
`image_id = ? OR duplicate_of_image_id = ?` and preloaded user/modifier/images.
`new_duplicate_report/2` moves this query into the context, retains the same OR
predicate and preloads, and adds `created_at DESC, id DESC` ordering. Existing
single-column indexes on both `image_id` and `duplicate_of_image_id` cover the
two OR branches. The added ordering is a presentation/tie-break requirement on a
small per-image collection; no composite index is recommended without evidence.

### Pair/report mutation and locking queries — changed, index-relevant shape but covered

The old accept/reverse/claim/unclaim/reject paths updated a loaded report by its
primary key. The current workflows first lock each distinct image by `images.id`
in ascending order, then lock the report by `id` plus its directional image-pair
predicates, and finally update by primary key. These are new row-lock lookup
queries, but `images_pkey`, `duplicate_reports_pkey`, and the existing image FK
indexes cover them; no index candidate.

Accept now updates competing reports using the same unordered pair OR predicate
but restricts state to `open`/`claimed` (the old query updated every other row and
excluded the subject ID). This is both a correctness/state-semantics change and
an index-relevant predicate change. Existing `image_id` and
`duplicate_of_image_id` indexes support the OR branches; the partial
`state_filtered` index supports the active-state subset. A pair/state composite
index would need measured evidence and is not recommended here.

Reverse accept's lookup changed from exact reverse pair plus `LIMIT 1` to the
same pair with subject-ID exclusion and `ORDER BY id DESC LIMIT 1`; the separate
directional indexes cover pair filtering, while no existing index covers the
requested ID ordering. A possible candidate is
`duplicate_reports(image_id, duplicate_of_image_id, id DESC)`, but the focused
production review rejects it at the observed p99 pair cardinality; the existing
directional indexes are sufficient for this infrequent lookup.

### Hide-image report rejection — unchanged (moved)

The `master` image-hide transaction used `UPDATE duplicate_reports SET state =
'rejected' WHERE state = 'open' AND (image_id = ? OR duplicate_of_image_id = ?)`.
`context-logic` delegates exactly this shape to
`DuplicateReports.put_reject_image_reports/3`. This is a context boundary move,
not a SQL-shape change. Existing image-side indexes and the state partial index
cover the predicates; no new index.

### Count — unchanged, covered

The staff counter remains `COUNT(id)` over `duplicate_reports WHERE state =
'open'` (the aggregate syntax changed from explicit `:id` to the Repo default).
The partial `state_filtered` index covers the lookup; no index action.

### Single-report load and preloads — changed, likely not index-relevant

The old controller/resource loading and current `Loader.fetch_and_authorize/5`
both locate a report by primary key. The current path adds authorization and
broader nested preloads; these are separate association queries and do not alter
the report locator access path. Primary-key/FK coverage is sufficient. Shared
`Loader`/authorization/preload details should be cross-referenced from
`shared.md`.

## Index summary

- Existing coverage: report `state`, active-state partial `state`, `created_at`,
  both image-pair direction columns, report/user/modifier FKs, report PK, image
  PK, and unique intensity `image_id`.
- The reverse-report latest-row composite `(image_id, duplicate_of_image_id,
id DESC)` was considered and rejected in the focused production review
  because p99 pair cardinality is five. Existing direction indexes are
  sufficient; no migration is proposed.
- No index action for visibility additions, deterministic tie-break ordering,
  lock-by-primary-key queries, hide-image rejection, or the count query absent
  workload evidence.

## Follow-ups

- The focused review identifies a correctness gap: automated perceptual reports
  should be allowed to target hidden images when that policy is intended, but
  `generate_reports/1` currently appends `hidden_from_users == false`.
- Per-image report SQL already selects both image-pair directions without an
  endpoint-visibility predicate. Verify the renderer/authorization path keeps
  those candidate reports visible to viewers who cannot see a hidden endpoint;
  do not add an index for this policy requirement.
