# Images SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 47 SQL-bearing sites in the Images-owned modules,
including moved controller loaders, association preloads, workers, and
image-owned interaction persistence (with detailed interaction contexts linked
from their own reports).

--- files ---
lib/philomena/images.ex
lib/philomena/images/image.ex
lib/philomena/images/query.ex
lib/philomena/images/search.ex
lib/philomena/images/search/scope.ex
lib/philomena/images/filtering.ex
lib/philomena/images/image_page.ex
lib/philomena/images/source.ex
lib/philomena/images/source_differ.ex
lib/philomena/images/source_input_form.ex
lib/philomena/images/tag_differ.ex
lib/philomena/images/tag_input_form.ex
lib/philomena/images/tagging.ex
lib/philomena/images/tag_validator.ex
lib/philomena/images/tag_lock.ex
lib/philomena/images/batch_tag_form.ex
lib/philomena/images/dnp_validator.ex
lib/philomena/images/thumbnailer.ex
lib/philomena/images/uploader.ex
lib/philomena/images/vote_form.ex
lib/philomena/images/subscription.ex
lib/philomena/images/attribution.ex
lib/philomena/images/search_index.ex
lib/philomena/image_faves.ex
lib/philomena/image_faves/image_fave.ex
lib/philomena/image_features/image_feature.ex
lib/philomena/image_hides.ex
lib/philomena/image_hides/image_hide.ex
lib/philomena/image_intensities.ex
lib/philomena/image_intensities/image_intensity.ex
lib/philomena/image_votes.ex
lib/philomena/image_votes/image_vote.ex
lib/philomena/interactions.ex
lib/philomena_web/image_loader.ex (master only; moved)
lib/philomena_web/image_navigator.ex (master only; moved)
lib/philomena_web/image_sorter.ex (master only; moved)
lib/philomena_web/controllers/image_controller.ex
lib/philomena_web/controllers/image/related_controller.ex
lib/philomena_web/controllers/image/reporting_controller.ex
lib/philomena_web/controllers/image/source_change_controller.ex
lib/philomena_web/controllers/image/source_controller.ex
lib/philomena_web/controllers/api/json/image/featured_controller.ex
lib/philomena_web/controllers/admin/approval_controller.ex
priv/repo/structure.sql
plans/sql-query-shape-audit.md

--- inventory ---
The current tree contains 47 SQL-bearing sites in the owned modules (including
Repo preloads, Multi lock/all/delete/update operations, aggregate, and worker
lookups), plus association preload queries. The paired master inventory also
includes the moved ImageLoader/ImageNavigator queries. OpenSearch request
bodies and search sort definitions are excluded. ImageFaves, ImageHides,
ImageVotes, ImageIntensities, and Interactions are included here only where
they are invoked as image-owned interaction/merge persistence; their detailed
row-query audit is assigned to their respective Wave D reports.

## Changed shapes

--- normalized shapes ---

- Member lookup/lock: `images` by primary key (`id = ?`), optionally with
  preloads. This is used by `Loader.fetch`, `Multi.lock_one`, API/report
  loading, all image mutations, thumbnail repair, and reindex loading. It is
  unchanged in relational shape from the old direct `where(id: ?)` queries;
  the new loader adds authorization/visibility handling outside the SQL query
  (see shared audit).
- Batch member lookup: `images WHERE id IN (?)`, with ascending `id` ordering
  for batch tag locking and sources/tags preloads. The current batch operations
  add a separate `hidden_from_users = false` read for visible counter/tag
  maintenance; the lock remains `id IN (?)`. This is a changed workload (new
  visibility predicate), but `id` PK coverage remains sufficient.
- Image listing/search/navigation/random/related/index-page operations are
  OpenSearch-backed and produce no PostgreSQL image-list SQL. Their Ecto SQL
  consists only of record preloads; those are unchanged association loads
  except for caller-selectable preloads.
- Featured member: `images INNER JOIN image_features ON image_features.image_id
= images.id WHERE images.hidden_from_users = false`, optionally excluding
  viewer hide rows via `NOT EXISTS(image_hides WHERE image_id = images.id AND
user_id = ?)`, ordered by `image_features.created_at DESC`, `LIMIT 1`, with
  user/intensity/source/tag preloads. This is new in `Images.show_featured_image`
  as a context query, moved from the API/activity callers; shape is paired with
  those callers and unchanged apart from the explicit hidden predicate being
  applied consistently.
- Image show: `images` member lookup with two inner-lateral aggregate subqueries
  counting tag changes (distinct changes and tags) and source changes, plus
  standard preloads. The lateral aggregate predicates remain
  `tag_changes.image_id = images.id` and `source_changes.image_id = images.id`;
  moved from `ImageController` into `Images.show_image`, unchanged and
  index-relevant only insofar as the child FK columns are used (covered by
  existing indexes in their owning contexts).
- Approval queue/count: `images WHERE approved = false ORDER BY id ASC` with
  preloads and pagination, and the same predicate with `COUNT(*)`. Both moved
  into `Images`; relational shape is unchanged and uses the existing partial
  `images_approved_index`.
- Image tag/source maintenance: child rows by `image_id`, image-tag rows by
  `(image_id, tag_id)`, and update/delete image rows by PK. Batch insert uses
  `ON CONFLICT DO NOTHING`; batch delete joins values `(image_id, tag_id)`.
  These shapes are unchanged or factored into Multi helpers; the additional
  visible-image read is the only material predicate change.
- Interaction preload: each image preload issues child association queries by
  `image_id`; `Interactions.user_interactions` unions four queries over
  hides/faves/votes with `image_id IN (?)` and `user_id = ?` (votes also
  `up = true|false`). The union and predicates are unchanged; current code
  short-circuits the empty-ID case before SQL.
- User-fave/vote/hide writes: delete rows by `(image_id, user_id)` (votes split
  by `up`), then update the image counter by `id`; uniqueness and PK/index
  coverage are unchanged. Batch erasure deletes by `user_id` and returns
  image IDs; existing user-ID indexes cover it. Intensity persistence changed
  from insert to upsert on `image_intensities(image_id)`; the unique index is
  the conflict target and no new index is indicated.

## Unchanged or non-index-relevant sites

--- delta classification ---

- `changed, index-relevant`: batch tag/revert workflows now issue an explicit
  `images.hidden_from_users = false` visibility query before counter updates.
  This is a semantic/correctness change, not evidence of a missing index: the
  driving `id IN (?)` predicate is PK-covered. The new featured query includes
  the image visibility predicate and viewer-hide `NOT EXISTS`; the latter is
  covered by the `(image_id, user_id)` unique hide index.
- `changed, likely not index-relevant`: transaction composition now uses
  `Multi.lock_one` before image updates and consolidates counter updates into
  PK-based `update_all`; selected columns/preloads and result mapping changed
  during the move. Intensity writes now use the existing unique image_id
  conflict target. Interaction loading adds empty-input short-circuiting and
  changes union construction without changing predicates.
- `unchanged`: approval queue/count, image-by-ID and batch-ID lookups, image
  tag/source child lookups, lateral show aggregates, interaction unions,
  user/image uniqueness deletes, and reindex worker lookup. These are mostly
  moved or split across context modules.
- `new/deleted/unpaired`: context APIs for list/search/navigation/random/
  related and API image loading are new public owners, but their list workload
  is OpenSearch plus unchanged PostgreSQL preloads; old controller helpers are
  deleted/moved rather than new SQL workloads.

## New, deleted, moved, or ambiguous sites

The deleted controller loaders and moved context APIs are paired above; no
ambiguous Images-owned SQL site remains. OpenSearch request bodies are outside
this PostgreSQL audit.

--- indexes/evidence ---

`priv/repo/structure.sql` is unchanged for image interaction indexes between
the relevant schema shapes (the dump token and unrelated commission/FK
changes are not query-shape evidence). Existing coverage includes:

- `images_pkey (id)`; `images_approved_index (approved) WHERE approved = false`;
  image indexes on `created_at`, `updated_at`, `user_id`, and partial
  `deleted_by_id`/`duplicate_id`.
- `index_image_features_on_image_id`, `index_image_features_on_created_at`,
  and `index_image_features_on_user_id`.
- unique `(image_id,user_id)` indexes on image faves, hides, and votes, plus
  ordinary `user_id` indexes on each.
- unique `image_intensities(image_id)` and `(nw,ne,sw,se)` comparison index.
- image sources `(image_id,source)`, image taggings `(image_id,tag_id)`, and
  gallery interactions indexes on `image_id`, `gallery_id`, and position.

No new index candidate is recommended from this context. The changed
visibility/batch query is PK-driven, approval work is covered by the existing
partial index, featured lookup has both join/filter indexes (though an
optional composite `image_features(created_at DESC, image_id)` could be
benchmarked only if `EXPLAIN` shows the current timestamp index plus join is a
hot bottleneck), and all interaction predicates are covered by existing
unique/user indexes. No representative EXPLAIN was run because the audit is
read-only and the dev database is not required for these already-covered
shapes.

--- follow-ups ---

- Link the `Loader` visibility/authorization SQL and shared interaction
  ownership findings from `shared.md`; avoid counting moved controller code a
  second time.
- If featured-image latency is observed, capture `EXPLAIN (FORMAT JSON)` for
  the join/order/limit query before considering a timestamp composite index.
- Keep the `images_approved_index` partial-index predicate aligned with the
  approval queue/count; do not replace it with a redundant general index.
- Verify the new hidden-image and merge-target correctness rules with targeted
  tests; they are semantic changes, not index recommendations.

## Follow-ups

See the follow-up items above; no migration or application-code change is part
of this audit.
