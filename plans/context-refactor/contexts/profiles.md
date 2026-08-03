# Profiles context plan

Source: `lib/philomena/profiles.ex`; consumers: profile page, IP history, and
fingerprint history controllers.

## Findings

- `load_profile_page/3` manually loads then authorizes a possibly `nil` user and
  translates several cases; sensitive detailed profile loading has another
  custom sequence.
- TODOs request structs for `admin_metadata`, IP history, and fingerprint
  history results, and ask to spell out `fp` as `fingerprint`.
- Sensitive metadata combines mod notes, name changes, IPs, fingerprints, and
  reports; authorization must be consistent across each component rather than
  inferred from a role.
- Private assembly helpers follow public functions, contrary to the requested
  layout.

## Work

- Use Users' shared safe slug locator: fetch a real visible user, then authorize
  `:show`; use a distinct `:show_details` gate for all sensitive views. Missing
  slugs are not-found for every actor.
- Introduce typed `ProfilePage`, `AdminMetadata`, `IpHistory`, and
  `FingerprintHistory` result structs. Rename public/result fields and function
  names from `fp` to `fingerprint`, with a coordinated controller/view change.
- Ensure sensitive subqueries execute only after the details authorization gate
  and are bounded/paginated. Delegate mod notes/name/IP/fingerprint/source-change
  queries through actor-scoped context APIs rather than raw public helpers.
- Move all private assembly/query helpers before the six public page APIs.
  Rewrite docs around deactivated profiles, forced filters, sensitive-data
  authorization, and result structures.

## TODO resolution

- Add all requested result structs and spell out fingerprint in the public API.

## Verification

- Test missing/deactivated/forbidden profiles for anonymous/user/staff, leakage
  prevention on every sensitive query, typed result contents, pagination, and
  profile/controller rendering.
