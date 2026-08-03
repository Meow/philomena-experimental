# UserIps context plan

Source: `lib/philomena/user_ips.ex`; consumers: IP-profile controller,
Profiles/SourceChanges, and internal attribution lookup.

## Findings

- `load_ip_profile/2` authorizes before parsing IP input and translates all parse
  errors to not-found; that order differs from the target member contract.
- `get_ip_for_user/1` is a public raw lookup with no actor and uses a user ID,
  while `masked_ip/1` is a presentation utility in the same context.
- Sensitive IP access shares the `:show, :ip_address` permission with fingerprint
  data, and private assembly follows the public APIs.

## Work

- Gate the class-level sensitive permission, safely parse/canonicalize the IP,
  assemble a typed profile, and keep forbidden versus invalid results stable.
  Align the permission subject with UserFingerprints/Profiles/SourceChanges.
- Inventory `get_ip_for_user/1`. Make it private or replace it with a narrow
  internal attribution service; no controller should be able to fetch a user's
  IP by arbitrary ID without the sensitive gate.
- Move masking to a dedicated value/helper module if it is used by views, or
  document it as a pure service API. Put private IP queries first and add complete
  specs/examples.

## Verification

- Test malformed IPv4/IPv6, normalized equivalents, matched/unmatched profiles,
  permission leakage, masking, and all cross-context consumers.
