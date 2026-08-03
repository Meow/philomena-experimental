# SourceChanges context plan

Source: `lib/philomena/source_changes.ex`; consumers: image/profile/IP/
fingerprint source-history controllers.

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
  sensitive `:show_details`/`:show, :ip_address` gates before history queries.
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
