# ImageFeatures context plan

Source: `lib/philomena/image_features.ex`; aggregate owner: `Philomena.Images`.

## Findings

- This generated-style CRUD context exposes list/get!/create/update/delete/change
  functions, but controller feature operations go through Images.
- `get_image_feature!/1` is a public bang loader that would bypass actor/image
  scoping if used from a request path.
- There is no actor or authorization contract because this is really a child
  persistence component.

## Work

- Inventory callers and fold feature persistence into private Images helpers if
  no independent service owns it. Otherwise retain only narrow loaded-image
  transaction/query functions and mark the module as internal infrastructure.
- Remove the public bang loader and generic CRUD/changeset surface. Feature
  creation/deletion must load and authorize its image through Images and use the
  action-specific ability there.
- Document uniqueness/date-range semantics and how feature changes affect the
  featured-image query/cache.

## Verification

- Keep persistence invariant tests here; put malformed/missing/forbidden image
  and feature-controller tests against the Images API.
