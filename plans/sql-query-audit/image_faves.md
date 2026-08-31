# ImageFaves SQL shape audit

Refs: master -> context-logic  
Status: complete  
Query sites inspected: 11

--- files ---

- `lib/philomena/image_faves.ex`
- `lib/philomena/image_faves/image_fave.ex`
- `lib/philomena_web/controllers/image/fave_controller.ex`
- `lib/philomena_web/controllers/image/favorite_controller.ex`
- `lib/philomena/images.ex` (fave operations, listing, counter cleanup, indexing preloads)
- `lib/philomena/images/image.ex` (fave associations)
- `lib/philomena/interactions.ex` (interaction lookup, source preload, migration caller)
- `lib/philomena/users/user_downvote_wipe.ex` (moved cleanup caller)
- `lib/philomena/data_exports/aggregator.ex` (ImageFave export query)
- `lib/philomena_query/batch.ex` (batch query builder used by cleanup)
- `priv/repo/structure.sql` and migration history containing the `image_faves` table/indexes

## Changed shapes

### Create/idempotent image favorite transaction (`put_fave_for_loaded_image/3`)

- Master: `ImageFaves.create_fave_transaction/2` (`lib/philomena/image_faves.ex:17`) issued one `INSERT INTO image_faves (image_id,user_id,created_at)` and an image counter `UPDATE images WHERE id = ?`; a duplicate favorite failed the unique constraint.
- context-logic: `ImageFaves.put_fave_for_loaded_image/3` (`lib/philomena/image_faves.ex:56`) first issues `DELETE FROM image_faves WHERE image_id = ? AND user_id = ?`, then the same one-row insert, followed by the same image counter update (`Images.put_image_counter_delta/5`) and a user-stat counter update.
- Delta: the delete is a new write-selection query; it makes the operation idempotent. The image and user counter updates still select by primary user/image IDs. The caller moved from the controller to `Images.create_image_fave/2`, where image loading/authorization and preloads are applied before the transaction.
- Index status: covered; no index action.
- Evidence: `image_faves` has unique B-tree `(image_id, user_id)`, which covers the new two-column delete and insert conflict/constraint path. `images.id` and `users.id` are primary keys. No additional index is justified for a single-row lookup.
- Confidence: high

### Delete image favorite transaction (`delete_fave_for_loaded_image/3`)

- Master: `ImageFaves.delete_fave_transaction/2` (`lib/philomena/image_faves.ex:38`) deleted by `image_id = ? AND user_id = ?`, then updated `images` by `id = ?` with the deleted-row count, and updated the user statistic.
- context-logic: `ImageFaves.delete_fave_for_loaded_image/3` (`lib/philomena/image_faves.ex:83`) retains the same favorite delete predicate. Counter changes are composed through `Images.put_image_counter_delta/5` and `UserStatistics.put_increment/3`.
- Delta: query composition and operation names changed, but the final relational predicates are unchanged. The image is loaded by `Loader.fetch_and_authorize/5` before the transaction, with `faves`-unrelated `sources` and `tags` preloads used by the response.
- Index status: covered; no index action.
- Evidence: the unique `(image_id, user_id)` index covers the delete lookup; image/user primary keys cover counter updates. The schema and `unique_constraint/3` are unchanged.
- Confidence: high

### User favorite cleanup (`delete_user_faves!/1`)

- Master: `Philomena.UserDownvoteWipe.perform/2` (`lib/philomena/user_downvote_wipe.ex:49`) built `ImageFave |> where(user_id: ^user.id) |> Batch.query_batches(id_field: :image_id)`. For each batch it selected `image_id` and ran `Repo.delete_all` on `user_id = ? AND image_id IN (?)`, then updated image counters by `id IN (?)`.
- context-logic: `Philomena.ImageFaves.delete_user_faves!/1` (`lib/philomena/image_faves.ex:94`) owns the same batch query and performs `Repo.all(select(batch, image_id))` followed by `Repo.delete_all(batch)`. `Philomena.Users.UserDownvoteWipe` calls it and applies the existing image/user counter updates.
- Delta: moved ownership and result handling (`Enum.uniq` image IDs); the batch loader still filters `user_id = ?`, orders/advances by `image_id`, limits each batch, and adds `image_id IN (?)` to the delete. No filter, join, or ordering requirement changed.
- Index status: covered; no index action.
- Evidence: existing `index_image_faves_on_user_id` covers the initial user batch scan. The unique `(image_id, user_id)` index is useful for the per-batch image-ID delete, and `images.id`/`users.id` cover counter updates. A composite `(user_id, image_id)` index is not supported by a plan observation and would duplicate existing coverage at additional write cost.
- Confidence: high

### Interaction migration insert (`put_migrate_image_interactions/2`)

- Master: `Philomena.Interactions.migrate_interactions/2` (`lib/philomena/interactions.ex:104`) preloaded source `favers`, mapped them to target `(image_id,user_id,created_at)` rows, and ran `insert_all(ImageFave, ..., on_conflict: :nothing)`.
- context-logic: `Philomena.Interactions.migrate_loaded_images/3` calls `ImageFaves.put_migrate_image_interactions/2` (`lib/philomena/image_faves.ex:112`), which performs the same bulk insert with `on_conflict: :nothing`, now `returning: [:user_id]` for bulk statistic increments. Source faves are still loaded by `repo.preload(source, :favers, force: true)` as part of the shared source interaction preload.
- Delta: no changed insert conflict target or row-selection predicate. `RETURNING` changes result mapping only. The source preload is still the `image_faves.image_id` association lookup, with no association `where` clause.
- Index status: covered; no index action.
- Evidence: unique `(image_id, user_id)` is the conflict target used by `on_conflict: :nothing`; the preload lookup uses its leading `image_id` column.
- Confidence: high

## Unchanged or non-index-relevant sites

- `Images.list_image_faves/2` (`lib/philomena/images.ex:3350`) replaces the old favorite controller's `load_and_authorize_resource` member lookup plus `[faves: :user]` preload. `Loader.fetch_and_authorize/5` still performs `Repo.get(Image, id)` and the same `image_faves WHERE image_id IN (...)` preload; staff-only vote/hide preloads are unrelated. Image primary key and the unique image-leading index cover these queries.
- `ImageFave` schema (`lib/philomena/image_faves/image_fave.ex:10`) is unchanged: no custom association `where`, Ecto still marks the `(user_id,image_id)` pair as the logical key, timestamps remain `created_at`, and the database unique constraint remains `index_image_faves_on_image_id_and_user_id`.
- `Image`'s `has_many :faves` and `has_many :favers, through: [:faves, :user]` (`lib/philomena/images/image.ex:36,44`) are unchanged and add no visibility predicate or ordering. `Images.indexing_preloads/0` still preloads `favers` through a selected user query; this is a projection change only, not an `image_faves` shape change.
- `Interactions.interactions_for_user/2` (`lib/philomena/interactions.ex:53`) still queries `image_faves` with `image_id IN (?) AND user_id = ?` inside the same `UNION ALL` interaction query. It is shared interaction logic and should be canonically reviewed in `shared.md`/the Interactions report, not duplicated as a changed ImageFaves query.
- `DataExports.Aggregator` (`lib/philomena/data_exports/aggregator.ex:110`) retains its `ImageFave` batch/export query keyed by `user_id` and `image_id`; no SQL shape delta was found.
- Profile recent favorites remain an OpenSearch `faved_by_id` query (`master` controller profile loader versus `context-logic` `Profiles`); OpenSearch request bodies are explicitly out of this PostgreSQL audit.

## New, deleted, moved, or ambiguous sites

- `create_fave_transaction/2` and `delete_fave_transaction/2` were replaced by loaded-image transaction steps and called from `Images.create_image_fave/2`/`delete_image_fave/2`. The favorite row predicates are paired and classified above; the surrounding authorization and image reload are not new `image_faves` SQL shapes.
- `UserDownvoteWipe` moved from the root module to `Users.UserDownvoteWipe`; its favorite deletion workload moved into `ImageFaves.delete_user_faves!/1` and is paired above.
- Interaction migration moved from `Interactions` into owner-specific transaction steps. The favorite insert remains paired above; the shared source preload and union interaction lookup have no ImageFaves-specific shape delta.
- No ambiguous ImageFaves SQL sites remain after searching both refs for `ImageFave`, `image_faves`, `faves`, and `favers` plus all `Repo` query operations.

## Follow-ups

- No index candidate is recommended. Existing primary/unique/user indexes cover all changed or moved PostgreSQL access paths, and no representative `EXPLAIN` was necessary for a missing path.
- The only semantic change is deliberate idempotency: create now removes an existing `(image_id,user_id)` row before inserting one and adjusts counters by the number deleted. This is correctness/transaction behavior, not an indexing concern.
- Shared interaction query/preload findings should be linked from the coordinator's shared report to avoid duplicate index recommendations.
