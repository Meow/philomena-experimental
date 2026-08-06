# UserFingerprints context plan

Source: `lib/philomena/user_fingerprints.ex`; consumer: fingerprint-profile
controller and Profiles/SourceChanges sensitive-data assembly.

## Status

Implemented in wave 1. Fingerprint profiles parse, lowercase, and validate the
supported browser fingerprint formats before applying the shared
`:show, :identity_metadata` gate. Invalid inputs are not found, while valid
unmatched inputs return an empty typed profile. The web cookie helper delegates
format knowledge to this domain context, and all sensitive-data consumers use
the same named permission. The Profiles wave added actor-scoped latest-row and
paginated user-history services, with cross-references bounded to 50 rows per
fingerprint.

## Findings

- `load_fingerprint_profile/2` is the only public API and correctly gates a
  sensitive permission, but the raw fingerprint locator has no validation or
  absence concept because the page is aggregate data rather than a schema row.
- The public function precedes its private assembly helper and documentation does
  not distinguish “no matches” from an invalid fingerprint.
- It authorizes `:show, :ip_address`, conflating IP and fingerprint data under one
  subject/action without stating that policy.

## Work

- Decide and encode a shared sensitive-identity permission subject (for example,
  `:identity_metadata`) used by UserIps, UserFingerprints, Profiles, and
  SourceChanges, rather than borrowing `:ip_address` accidentally.
- Validate/canonicalize fingerprint input. Return not-found for invalid formats;
  intentionally return an empty typed profile for a valid unmatched fingerprint
  only if that supports investigations without existence ambiguity.
- Move private queries/assembly before the public loader; add a typed result if
  the existing profile struct is insufficient and document masking/sensitivity.

## Verification

- Test invalid, valid-unmatched, and matched fingerprints for every auth level,
  plus consistency with Profiles and SourceChanges.
