# Galleries context plan

Source: `lib/philomena/galleries.ex`; consumers: gallery HTML/API search/show,
image/order/read/subscription/report controllers, indexing, and user erasure.

## Findings

- Early loaded-record CRUD/image membership functions remain public, including
  `delete_gallery/3` only because `Users.Eraser` calls it.
- `load_authorized_gallery/3` has a custom parse/load/auth `else`; other member
  paths parse IDs independently. New/edit use `verify_not_banned/1` while writes
  use `verify_write_access/1`.
- Gallery-image add/remove/reorder must validate two resources and ownership;
  several operations have bespoke ID parsing and transaction result handling.
- `user_image_galleries/2` is explicitly marked as an unbounded query.

## Work

- Use one shared gallery member loader for all IDs and actions. Apply
  `verify_write_access/1` to new/edit and every mutation; make absent result
  independent of actor grants.
- Load gallery images via `Loader`/Images visibility, enforce gallery ownership
  and membership in the database query, and make add/remove/reorder idempotency
  and ordering failures explicit.
- Bound `user_image_galleries/2`: paginate it for a controller, limit it for a
  selector, or replace it with an existence/ID query suited to its actual caller.
- Introduce a named erasure service in Galleries and make generic loaded
  `delete_gallery/3` private. Classify/restrict raw CRUD, reindex, reorder-worker,
  and notification helpers as private or documented service APIs.
- Reorder private persistence/query/index/notification functions before public
  APIs. Document visibility, watcher side effects, worker scheduling, and search
  consistency.

## TODO resolution

- Replace the eraser-driven public delete escape hatch with a narrow API.
- Eliminate the unbounded user/image gallery query.

## Verification

- Cover malformed/missing/forbidden galleries and images, hidden images,
  duplicate membership, wrong membership removal, invalid reorder sets,
  subscriptions/read state, erasure, and OpenSearch updates.
