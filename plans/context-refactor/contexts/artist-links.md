# ArtistLinks context plan

Source: `lib/philomena/artist_links.ex`; consumers: profile artist-link and admin
verification/rejection/contact controllers plus automatic verification jobs.

## Findings

- The context loads profiles by slug itself (an existing TODO calls this
  ownership questionable) and mixes `actor`, `actor.user`, ID-only artist-link
  loads, and slug-plus-ID controller contracts.
- The update doc/TODO questions whether `slug` is needed; currently the loaded
  link already carries its user/profile relationship.
- Low-level `create_artist_link/1`, `verify_loaded_link/1`, and
  `automatic_verify!/1` share the public surface with actor-scoped APIs.
- `authorized_profile/3` and `authorized_artist_link/3` reproduce custom missing
  versus unauthorized translation and are placed amid public functions.

## Work

- Make Profiles/Users expose one actor-aware profile locator suitable for
  cross-context use, or load a link through a query scoped to the profile slug.
  Do not independently reinterpret profile visibility here.
- Retain slug on show/edit only if it is used to enforce parent membership. If
  the route is link-ID canonical, remove slug from context/controller signatures;
  if the route stays nested, reject a link owned by a different slug as not-found.
- Use actual actions for link operations and `verify_write_access/1` for both
  form loaders and mutations. Stop passing only `actor.user` at the public edge.
- Rename/publicly document the automatic-verifier entry point as a service API;
  make loaded-record CRUD and transition helpers private.
- Move private profile/link loaders, state transitions, and mail/log helpers
  before the public API. Rewrite docs around verification state transitions,
  notifications, and failure shapes.

## TODO resolution

- “load a profile by slug is weird”: delegate the locator or enforce nested
  ownership through a shared Users/Profiles API.
- “slug probably isn't needed”: decide from route semantics and remove it unless
  it proves parent membership; never keep an ignored security parameter.

## Verification

- Test mismatched profile/link pairs, hidden/deactivated profiles, invalid IDs,
  every verification transition, and write-access parity between new/edit and
  create/update.
