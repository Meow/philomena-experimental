# Bans context plan

Source: `lib/philomena/bans.ex`; consumers: fingerprint, subnet, and user-ban
admin controllers plus request-time ban lookup.

## Findings

- Three near-duplicate admin flows manually authorize a class, load an ID, edit,
  update, delete, and log. The repetition makes their error precedence easy to
  drift.
- Raw create helpers and `change_subnet/1` are public; a TODO notes the latter is
  exposed only because a controller calls it.
- `target_user/1` has a TODO to remove, and `find/3` ends in a role-specific
  deletion constraint whose TODO questions its necessity.
- `verify_can_delete/1` directly pattern-matches the user role instead of using
  the authorization layer.

## Work

- Introduce one private member-flow pattern shared conceptually (not necessarily
  metaprogrammed) by fingerprint/subnet/user bans: action-specific class gate,
  shared safe ID load, instance authorization, transaction, moderation log.
- Move changeset construction behind `new_*_ban/1` and edit results so no
  controller needs `change_subnet/1`; make raw CRUD functions private or narrow
  service APIs for fixtures.
- Remove `target_user/1` by making `new_user_ban/2` safely load the requested
  target and return not-found/unauthorized. Avoid a separate unguarded lookup.
- Replace `verify_can_delete/1` and other role patterns with named authorization
  actions. Resolve the “unnecessary constraint” TODO by testing whether admin
  self/peer deletion is meant to be forbidden; encode that in Ability if it is.
- Keep request-time `find/3` public and deliberately unauthenticated, but separate
  it from admin CRUD in docs/layout and specify precedence when multiple bans
  match.

## Verification

- Use one shared test matrix for all three ban kinds: each action and auth level,
  malformed/missing IDs, constraint violations, log creation, and delete rules.
- Test `find/3` combinations independently so stricter admin changes cannot alter
  request-time ban selection accidentally.
