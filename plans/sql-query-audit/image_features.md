# ImageFeatures SQL shape audit

Refs: master -> context-logic  
Status: complete  
Query sites inspected: 8 production sites (the former context CRUD operations,
two featured-image controller queries, and the current Images read/write paths),
plus the ImageFeature schema and relevant callers.

--- files ---

- `lib/philomena/image_features.ex` (master only; removed on context-logic)
- `lib/philomena/image_features/image_feature.ex`
- `lib/philomena/images.ex` (`show_featured_image/2`, `create_image_feature/2`)
- `lib/philomena/activities.ex` (`load_featured_image/2` caller)
- `lib/philomena_web/controllers/api/json/image/featured_controller.ex`
- `lib/philomena_web/controllers/image/feature_controller.ex`
- `lib/philomena_web/controllers/activity_controller.ex` (master featured query)
- `priv/repo/structure.sql`

## Changed shapes

### Featured image selection (activity page and featured-image API)

- Master: the activity controller's inline query (former
  `PhilomenaWeb.ActivityController.index/2`, around lines 60-70) selected from
  `images`, inner-joined `image_features` on `image_features.image_id =
images.id`, fixed `images.hidden_from_users = false`, and ordered by
  `image_features.created_at DESC`, `LIMIT 1`. For an authenticated activity
  request, `filter_hidden/3` added `NOT EXISTS (SELECT 1 FROM image_hides
WHERE image_hides.image_id = images.id AND image_hides.user_id = $user)`;
  anonymous requests and the `hidden=1` branch had no such predicate. Its
  preload was `sources` and `tags:aliases`.
- Master: the API controller's inline query (around lines 14-24) had the same
  join, hidden-image predicate, order, and limit, but never applied the
  personal-hide `NOT EXISTS` predicate. It preloaded `user`, `intensity`,
  `sources`, and `tags:aliases`.
- context-logic: `Philomena.Images.show_featured_image/2` (lines 727-744)
  owns the query used by both `Philomena.Activities.load_featured_image/2`
  (lines 88-95) and the API controller. The base shape remains `images INNER
JOIN image_features ON image_features.image_id = images.id WHERE
images.hidden_from_users = false ORDER BY image_features.created_at DESC
LIMIT 1`, with the same rich preload as the API. For authenticated actors
  and `include_hidden? == false`, it adds the `image_hides` correlated
  `NOT EXISTS`; anonymous actors and `include_hidden? == true` omit it.
- Delta: the relational join, fixed visibility predicate, ordering, and
  pagination are unchanged. The activity branch behavior is equivalent when
  `scope.hidden` is false/default versus `true`; the API now also excludes the
  requesting user's hidden images (`show_featured_image(actor, false)`), which
  is a semantic visibility change and not merely code movement. The common
  helper also adds the `authorize(actor, :index, Image)` gate before running
  the query. Preload expansion for the activity page is not an access-path
  change.
- Index status: covered; no index action.
- Evidence: current `structure.sql` (and master, unchanged for this table)
  has `index_image_features_on_created_at (created_at)` for the descending
  top-one ordering and `index_image_features_on_image_id (image_id)` for the
  join. The new correlated lookup is covered by the unique
  `index_image_hides_on_image_id_and_user_id (image_id, user_id)`. PostgreSQL
  can use the existing `created_at` B-tree in reverse order; no composite
  recommendation is justified without representative plans/workload data.
- Confidence: high.

### Feature creation and locking

- Master: `Philomena.Images.feature_image/2` (around lines 261-265) performed
  only an `INSERT` of `%ImageFeature{user_id, image_id}` after the controller's
  `load_and_authorize_resource` had already selected the image by primary key.
  The controller then separately wrote the moderation log.
- context-logic: `Philomena.Images.create_image_feature/2` (lines 1723-1740)
  first calls shared `Loader.fetch_and_authorize(Image, actor, :feature,
image_id)` (a primary-key member lookup), then in a `Philomena.Multi` performs
  `SELECT ... FROM images WHERE images.id = $id FOR UPDATE` via
  `Multi.lock_one/2`, inserts the feature, and records the moderation log in
  the transaction.
- Delta: a new image member lookup and a locking lookup were added around the
  same feature insert. Both predicates are `images.id = $id`; the write
  predicate and feature insert columns are unchanged. This is
  `changed, index-relevant` as a query workload, but the access path is fully
  covered by `images_pkey`; no index candidate.
- Index status: covered; no index action.
- Evidence: `images.id` is the primary key in `structure.sql`. The shared
  `Loader` behavior is canonicalized in the shared audit (member lookup and
  authorization helper).
- Confidence: high.

## Unchanged or non-index-relevant sites

- The master-only `Philomena.ImageFeatures` CRUD functions
  (`list_image_features/0` `Repo.all`, `get_image_feature!/1` `Repo.get!`,
  `create_image_feature/1` `Repo.insert`, `update_image_feature/2`
  `Repo.update`, and `delete_image_feature/1` `Repo.delete`) were removed with
  `lib/philomena/image_features.ex`; there is no current context API
  counterpart. The list query was an unfiltered full-table scan with no
  current production caller identified. `get`/delete are primary-key member
  operations; update changes no row-selection predicate. Record as deleted
  context surface, not as an index recommendation.
- `ImageFeature`'s schema association declarations (`belongs_to :image` and
  `belongs_to :user`) are unchanged apart from the type declaration and a
  default changeset argument. No association preload query is defined in the
  schema itself.
- The feature insert's `ImageFeature.changeset/1` now has a default `%{}`
  argument; it still casts no fields and validates no fields. This has no SQL
  shape effect.
- `Images.show_featured_image/2` is a moved/consolidated owner for the two
  controller queries. The API and activity callers do not add independent SQL
  after the helper; `Interactions.user_interactions/2` is a shared
  cross-context query owned by the Interactions audit.

## New, deleted, moved, or ambiguous sites

- `lib/philomena/image_features.ex` is deleted on context-logic. Its generic
  CRUD API appears to have been intentionally retired; feature creation moved
  into `Images.create_image_feature/2`, while featured-image reading moved
  from both controllers into `Images.show_featured_image/2`.
- The current API behavior's personal-hide predicate differs from master API
  behavior. This should be reviewed as a visibility/correctness decision; the
  supporting `image_hides` unique index is already present. Link shared
  `Loader`/authorization and visibility findings during coordinator synthesis.
- No EXPLAIN was run: the local audit has no representative production
  cardinality/workload evidence, and all changed lookup paths have clear
  primary/unique/index coverage.

## Follow-ups

- Confirm whether the API should hide the caller's personally hidden featured
  image, since this is the only material visibility delta found here.
- No ImageFeatures-specific migration or index change is recommended.
