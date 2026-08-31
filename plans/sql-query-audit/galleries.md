# Galleries SQL shape audit

Refs: master -> context-logic  
Status: complete

Query sites inspected: 10

--- files ---

- `lib/philomena/galleries.ex`
- `lib/philomena/galleries/gallery.ex`
- `lib/philomena/galleries/interaction.ex`
- `lib/philomena/galleries/gallery_page.ex`
- `lib/philomena/galleries/query_builder.ex`
- `lib/philomena/galleries/query_form.ex`
- `lib/philomena/galleries/reorder_form.ex`
- `lib/philomena_web/controllers/gallery_controller.ex`
- `lib/philomena_web/controllers/gallery/image_controller.ex`
- `lib/philomena_web/controllers/gallery/order_controller.ex`
- `lib/philomena_web/controllers/gallery/read_controller.ex`
- `lib/philomena_web/controllers/gallery/report_controller.ex`
- `lib/philomena_web/controllers/gallery/subscription_controller.ex`
- `lib/philomena_web/controllers/api/json/search/gallery_controller.ex`
- `lib/philomena/images.ex` (moved gallery-interaction operations/callers)
- `lib/philomena/loader.ex` (shared member loader used by Galleries)
- `lib/philomena_query/batch.ex` (batch query builder used by deletion)
- `priv/repo/structure.sql`

## Findings

### 1. Gallery member loading and CRUD

- **Changed, likely not index-relevant / shared:** the old `Repo.get!(Gallery,
id)` and controller resource loader are replaced by
  `Loader.fetch_and_authorize/5`, which still performs a primary-key lookup and
  then the same association preloads (`user`, thumbnail sources/tags/aliases).
  The authorization and malformed-ID behavior changed, but the relational
  access path is the gallery primary key. See the shared Loader audit for the
  common shape.
- **Unchanged relational shape:** gallery insert and update remain writes keyed
  by the normal Ecto insert/update operation; moving them into `Philomena.Multi`
  and adding authorization/reindex callbacks does not add a row-selection
  predicate.

### 2. Add/remove gallery images

- **Changed, index-relevant:** `add_image_to_gallery/2` became
  `create_gallery_image/3`. The current transaction locks the image by
  `images.id`, then the gallery by `galleries.id`, computes
  `MAX(gallery_interactions.position)` with `gallery_id = ?`, inserts a
  membership, and updates the gallery by `id`. Master locked only the gallery
  by `id`, did the same max-position aggregate and membership insert, then used
  `UPDATE galleries WHERE id = ?` (also setting `updated_at`).
- **Changed, index-relevant:** `remove_image_from_gallery/2` became
  `delete_gallery_image/3`. In addition to the new image and gallery primary-key
  locks, current explicitly locks the interaction with
  `gallery_id = ? AND image_id = ?`, then deletes that row and updates the
  gallery by `id`. Master deleted all matching interactions with the same
  two-column predicate after only locking the gallery. The unique
  `(gallery_id, image_id)` index covers the lookup and the foreign-key indexes
  cover the related joins; no new candidate is warranted.
- The existing `gallery_id, position` index covers the max-position aggregate
  (and the same access path is used by the current add operation). Primary keys
  cover all gallery/image lock and update predicates.

### 3. Gallery deletion and cleanup

- **Changed, index-relevant:** master first selected all member image IDs with
  `gallery_id = ?`, then closed reports and deleted the gallery. Current first
  batches interaction rows by `image_id` (the shared `Batch.query_batches`
  loader performs ascending `image_id > ?`, `ORDER BY image_id`, `LIMIT 1000`
  probes), and per batch locks the gallery by `id`, deletes interactions by
  `gallery_id = ? AND image_id IN (...)`, and decrements the gallery counter by
  `id`. A final transaction deletes remaining interactions by `gallery_id = ?`,
  closes reports, and deletes the gallery by primary key.
- Existing `index_gallery_interactions_on_image_id` covers the batch probe;
  `(gallery_id, image_id)` and `gallery_id` indexes cover the delete predicates;
  `reports_gallery_id_index` is partial on non-null gallery IDs and covers the
  report close lookup. No missing index is evident.
- The new locking/cleanup sequence is a concurrency and write-shape change,
  but does not create an uncovered lookup column. The old pre-delete image-ID
  select is no longer a separate unbatched query.

### 4. Reordering

- **Changed, index-relevant:** the old asynchronous `perform_reorder/2` loaded
  the gallery by primary key, selected interactions with
  `gallery_id = ? AND image_id IN (...) ORDER BY position` (direction based on
  gallery setting), then issued one `UPDATE gallery_interactions WHERE id = ?`
  per changed row. Current `update_gallery_order/3` first locks submitted
  `images.id` rows in ascending ID order, locks the gallery by ID, validates
  membership with `gallery_id = ? AND image_id IN (...)`, reloads the affected
  interactions with the same filter/order, and uses `insert_all` upserts with
  conflict target primary key and replacement of `position`.
- Existing primary-key, unique `(gallery_id, image_id)`, and
  `(gallery_id, position)` indexes cover the lock, membership, and ordered
  gallery access paths. The filter is an `IN` list and its global ordering may
  still require a sort; without representative `EXPLAIN`/workload evidence,
  do not add a speculative composite index.
- The worker query was removed and the operation is now synchronous/transactional;
  this is a workload/concurrency change, not evidence of a new index need.

### 5. New owner gallery selector

- **New/unpaired, index-relevant:** `gallery_choices_for_image/2` adds a
  collection query on `galleries` with `user_id = ?`, an inner lateral
  correlated subquery checking `gallery_interactions.image_id = ? AND
gallery_id = galleries.id`, `ORDER BY galleries.updated_at DESC`, and
  `LIMIT 100`. The existing `index_galleries_on_creator_id` covers the owner
  predicate. The unique `(gallery_id, image_id)` index covers the correlated
  interaction existence check. There is no evidence for adding an
  `(user_id, updated_at)` index solely for this bounded selector; the current
  owner index may filter/sort and should be validated with production plans if
  this is hot.

### 6. Image-owned operations moved into Galleries

- **Unchanged, moved:** `put_remove_image_interactions/2` now owns the SQL
  previously in `Images.remove_gallery_interactions_multi/2`: update galleries
  joined to interactions on `image_id = ?` (decrementing `image_count` and
  returning gallery IDs), followed by delete interactions with `image_id = ?`.
  `index_gallery_interactions_on_image_id` covers both operations; this is a
  context move, not a shape delta.
- **Unchanged, moved:** `put_migrate_image_interactions/3` contains the former
  image merge SQL: select target gallery IDs by `image_id = ?`; update source
  rows where `image_id = ?` and `gallery_id NOT IN (target IDs)`; select/delete
  leftover source rows by `image_id = ?`; then update galleries where
  `id IN (...)`. Existing image and gallery indexes cover these predicates.

### 7. Non-SQL search paths

`list_galleries/3`, `query_galleries/3`, gallery page image windows, and the
query builder/form issue OpenSearch requests and preloads; their request bodies,
sorts, and mappings are outside this PostgreSQL audit. `perform_reindex/2` has
the same `galleries` field-`IN` query as master and is unchanged relationally.

## Index inventory and recommendation

Relevant current `structure.sql` indexes: galleries primary key; `galleries`
`user_id` and `thumbnail_id`; gallery-interactions primary key; ordinary
`gallery_id`, `image_id`, and `position`; unique `(gallery_id, image_id)`; and
`(gallery_id, position)`. The interaction foreign keys are indexed as needed by
these existing indexes. The report-close path is covered by the partial
`reports_gallery_id_index`.

**Recommendation:** no new index candidate from the Galleries audit. Validate
the new owner selector and reordered `IN` + `ORDER BY position` query with
representative `EXPLAIN (FORMAT JSON)` if workload data shows them to be hot;
do not add a generic index based on source shape alone.

## Correctness/concurrency notes (not index recommendations)

The current implementation deliberately establishes image-before-gallery lock
ordering for add/remove/reorder and batches gallery deletion to coordinate with
image hide/merge operations. This is a semantic/concurrency change distinct
from index coverage.
