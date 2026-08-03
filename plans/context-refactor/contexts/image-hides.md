# ImageHides context plan

Source: `lib/philomena/image_hides.ex`; aggregate owner: `Philomena.Images`.

## Findings

- Like ImageFaves, this module exposes only transaction steps while Images owns
  controller loading, authorization, and forced-filter rules.
- Its public surface does not signal that callers must pass authorized loaded
  resources or that counters are part of the transaction invariant.

## Work

- Keep or fold the module based on its caller inventory. If retained, expose
  only clearly named internal Multi steps accepting loaded structs and document
  that they are not authorization boundaries.
- Define idempotent create/delete behavior and exact counter changes. Ensure a
  duplicate hide or repeated delete cannot drift counters.
- Keep all request IDs and actor checks in Images; never add an alternate raw-ID
  API here.

## Verification

- Test transaction uniqueness and counters here; test forced filters,
  write-access, and hidden-image visibility through Images/controller tests.
