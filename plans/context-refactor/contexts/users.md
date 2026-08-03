# Users context plan

Source: `lib/philomena/users.ex`; consumers: authentication/registration/session/
settings/profile/admin account controllers, many contexts, workers, and mailers.

## Findings

- The 2,200-line module exposes authentication primitives, account CRUD,
  controller orchestration, admin actions, profile editing, tag watches, avatar/
  rename/deactivation services, and indexing in one mixed public surface.
- Member loading by ID/slug is inconsistent: `get_user!`, `load_profile`, several
  custom authorize-`nil` loaders, and `load_managed_user`. Missing result can
  depend on actor grants.
- Many form loaders use `verify_not_banned/1`, while writes use
  `verify_write_access/1`. Public functions sometimes accept Actor, User, token,
  slug, or loaded records without clear boundary grouping.
- Direct `Canada.Can.can?` and role checks remain in staff/filtering code. Generic
  `change_user`, `update_user`, filter/verify/deactivate helpers and indexing
  functions allow other modules to couple to persistence details.

## Work

### Define sub-surfaces without losing ownership

- Keep Users as the owning context but explicitly group private mechanics first,
  then documented public services: authentication/tokens, registration/self-
  service settings, actor-scoped profile editing, admin account management, and
  workers/indexing. Consider internal submodules for token/avatar/rename
  transactions only if the top-level context remains the sole controller API.
- Inventory every public function/caller. Make generic CRUD/changeset, loaded
  modifiers, role/filter helpers, and reindex mechanics private unless a fixture,
  worker, or context requires a narrow named service.

### Normalize locators and authorization

- Provide shared safe user locators by ID and slug with explicit inclusion or
  exclusion of deactivated accounts. Fetch a real row before instance
  authorization; delete `get_user!` and custom authorize-`nil` request paths.
- Use actor-first public signatures on every request path. Authentication token
  services are the deliberate exception and must document why they have no Actor.
- Replace every form `verify_not_banned/1` with `verify_write_access/1`, including
  description, scratchpad, avatar, and rename preparation. Ensure admin form and
  mutation action pairs (`:edit`/`:update`, erase, force-filter, unlock, verify,
  wipe) share prerequisites and target restrictions.
- Replace direct Canada and role gates with Ability actions. Staff category
  presentation may group by role after authorization, but must not decide access.

### Transactions and cross-context ownership

- Make avatar storage/database/log changes, rename plus name-history/index jobs,
  deactivation/reactivation tokens, settings/filter updates, and admin destructive
  actions transactional or explicitly after-commit. Compose moderation logs in
  the owning transaction.
- Replace cross-context generic calls from Eraser, UserWipe, UserDownvoteWipe,
  Comments, Galleries, and Tags with narrow service contracts defined by the
  owning domain. Do not keep public loaded CRUD solely for erasure.
- Coordinate with Filters to replace `Philomena.Schema.TagList` denormalized
  settings fields with normalized relations, one alias-resolution path, and a
  backfill that preserves current hidden/spoiler tag choices.
- Centralize typed results for admin edit/profile forms rather than returning
  ad-hoc tuples/maps. Document deactivated/confirmed/TOTP behavior, token
  invalidation, jobs, mail, and sensitive side effects.

## Verification

- Build a locator matrix for malformed/missing/deactivated/forbidden ID and slug
  targets across self, other user, moderator, and admin.
- Cover form/write parity for every self-service/admin action; token lifecycle and
  enumeration resistance; TOTP; settings/filter restrictions; avatar failures;
  rename/history races; deactivation/reactivation; erasure/wipe jobs; moderation
  logs; mail; and indexing.
- Migrate in small surfaces, running the corresponding controller tests plus
  `users_test.exs`; reserve full CI for the completed Users wave.
