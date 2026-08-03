# ImageFaves context plan

Source: `lib/philomena/image_faves.ex`; aggregate owner: `Philomena.Images`.

## Findings

- The module exposes only transaction-building create/delete functions. It is a
  persistence component, not a controller context, but its generic public docs
  currently read like a standalone API.
- Authorization, image loading, and write prerequisites live in Images; callers
  could bypass them if these transaction functions spread beyond the aggregate.

## Work

- Confirm with a caller inventory that only Images composes these functions. If
  so, treat them as a documented internal service and name them explicitly as
  loaded-image transaction steps; otherwise fold them into Images.
- Require already-loaded image/user structs and make their invariant clear:
  callers must have completed actor authorization. Do not add a competing loader
  or authorization convention here.
- Keep persistence helpers before the small public service surface and document
  idempotency, uniqueness conflicts, counter updates, and Multi change names.

## Verification

- Test the component transaction for duplicate create/delete and counter
  correctness, while keeping authorization and malformed-ID cases in Images.
