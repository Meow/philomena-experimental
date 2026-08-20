# Galleries context plan

Source: `lib/philomena/galleries.ex`; consumers: gallery HTML/API search/show,
image/order/read/subscription/report controllers, indexing, and user erasure.

## Implementation status

Complete for wave 4.

- Request-facing collection, search, member, form, membership, reorder, read,
  and subscription operations are Actor-first and authorize named actions.
  New/edit and content/subscription mutations share the write-access
  prerequisite; notification clearing remains an explicit read-state
  exemption. One Loader path now makes malformed and missing gallery IDs
  consistently not-found, independent of actor grants.
- Actor is authoritative for gallery page viewer state. Gallery/image
  membership mutations independently authorize the visible image and owning
  gallery. Duplicate adds return a changeset error and absent removals return
  `{:error, :not_found}`;
  hidden, malformed, and missing images are rejected before persistence.
- Reorders accept unique integer or decimal-string IDs from the current gallery
  page. Omitted memberships retain their position slots; invalid requests are
  rejected, and membership is revalidated while the gallery row is locked so
  stale requests cannot partially reorder a gallery.
- The image-page gallery selector was replaced with the Actor-first
  `gallery_choices_for_image/2` and capped at 100 most-recently-updated rows.
  The caller now receives only the authenticated actor's choices; anonymous
  actors receive none.
- Loaded-record CRUD, membership persistence, synchronous reorder, queries, and
  notification steps are private and precede the public API. User erasure uses
  the narrow `erase_user_galleries/2` service. User-rename, index queue, and
  subscription notification callbacks remain explicit documented service APIs.
- Context/controller coverage now includes malformed, missing, and forbidden
  galleries/images; duplicate and absent membership errors; invalid and stale
  reorder sets; actor-over-Scope state; read/subscription state; bounded
  selectors; erasure/report closure; and search-backed listing/page behavior.

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
  and membership in the database query, and make duplicate/absent membership
  and ordering failures explicit.
- Bound `user_image_galleries/2`: paginate it for a controller, limit it for a
  selector, or replace it with an existence/ID query suited to its actual caller.
- Introduce a named erasure service in Galleries and make generic loaded
  `delete_gallery/3` private. Classify/restrict raw CRUD, reindex,
  reorder persistence, and notification helpers as private or documented
  service APIs.
- Reorder private persistence/query/index/notification functions before public
  APIs. Document visibility, watcher side effects, synchronous behavior, and
  search consistency.

## TODO resolution

- Replace the eraser-driven public delete escape hatch with a narrow API.
- Eliminate the unbounded user/image gallery query.

## Verification

- Cover malformed/missing/forbidden galleries and images, hidden images,
  duplicate membership, wrong membership removal, invalid reorder sets,
  subscriptions/read state, erasure, and OpenSearch updates.
