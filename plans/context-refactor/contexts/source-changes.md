# SourceChanges context plan

Source: `lib/philomena/source_changes.ex`; consumers: image/profile/IP/
fingerprint source-history controllers.

## Implementation status

Complete for wave 4.

- Image history resolves through Images' canonical visible-image loader, so
  malformed and absent IDs are consistently not-found while real hidden images
  remain unauthorized to ordinary viewers.
- User history resolves active profiles through Users and requires
  `:show_details` before either the page or distinct-image count query runs. The
  profile page exposes the history link only to viewers with that permission.
- IP and fingerprint locators are normalized and validated before the shared
  `:identity_metadata` gate. Malformed values are always not-found, valid values
  without history return empty pages, and fingerprint format rules are shared
  with UserFingerprints.
- Every controller-facing history API returns a typed `SourceChangePage` with a
  resolved target, page, and optional range/count metadata. User counts derive
  from the same filtered query as rows; the remaining count service accepts an
  already-loaded image and is documented as Images transaction composition.
- Private target, validation, and history-query helpers precede the public API,
  and controller/context coverage pins missing, malformed, forbidden, hidden,
  deactivated, pagination, masking, filtering, and rendering behavior.

## Findings

- Five read APIs use different locators and custom authorization/error branches:
  image ID, user slug, IP parsing, and raw fingerprint.
- Image source changes are not consistently delegated through Images visibility;
  sensitive user/IP/fingerprint history uses separate permission subjects and
  may reveal existence/counts if query order drifts.
- Public functions are mostly API-shaped, but private queries come after them and
  docs encode current authorization ordering rather than one shared contract.

## Work

- Delegate image and user loading to their owning actor-scoped safe loaders; run
  sensitive `:show_details` and `:show, :identity_metadata` gates before history
  queries.
- Normalize locator failures: malformed/absent image/user/IP are not-found, while
  a real subject/history forbidden to the actor is unauthorized. Define raw
  fingerprint validation rather than accepting every string silently.
- Consider a typed `SourceChangePage` result so every history API returns the
  same pagination/target metadata shape. Ensure counts obey the same visibility
  gate as rows.
- Move private target/history queries before public APIs and document sensitive
  data, masking, pagination, and absence behavior with examples.

## Verification

- Matrix-test malformed/missing/hidden image, user, IP, and fingerprint targets;
  sensitive permission leakage; pagination/count parity; and controller output.
