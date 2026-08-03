# ImageIntensities context plan

Source: `lib/philomena/image_intensities.ex`; aggregate owner: media duplicate
detection and `Philomena.Images`.

## Findings

- The module is generated CRUD with a public `get_image_intensity!/1`, but it is
  not a controller boundary and has no authorization.
- Generic create/update/delete/change functions make it unclear whether intensity
  rows are caller-managed data or derived media-pipeline state.

## Work

- Treat intensities as derived internal data. Inventory analyzer/worker callers
  and replace generic CRUD with the minimum service API needed to upsert/delete
  results for an already-loaded image.
- Remove request-facing bang lookup. If a lookup is required, scope it by image
  and return a normalized non-raising result.
- Document replacement semantics, uniqueness by image/type, and transaction
  coupling with image processing; keep private persistence first.

## Verification

- Test upsert/replacement, duplicate constraints, image deletion cleanup, and
  media-pipeline failure behavior rather than controller authorization here.
