# Donations context plan

Source: `lib/philomena/donations.ex`; consumers: admin donation and per-user
donation controllers.

## Status

Implemented as a wave 1 query-loader exemplar. Routed actions are distinct,
the per-user form verifies write access and safely loads the slug through
`Loader.one/1`, financial-history access is authorized against the real target,
and raw insertion is private.

## Findings

- List, user list, and create all authorize `:index`; creation has no distinct
  permission.
- Per-user listing performs a custom slug lookup and `else` translation rather
  than using the shared Users locator.
- `insert_donation/1` and `create_donation/1` are both public, obscuring the
  controller boundary, and the module layout is mixed.

## Work

- Authorize listing with `:index` and creation with `:new`/`:create`; add ability
  rules if the same roles currently happen to satisfy both.
- Use a shared safe Users slug loader and explicitly authorize access to the
  target's donation history. Do not treat general user visibility as permission
  to see financial data.
- Make the raw insert private; expose one actor-first create API that returns the
  donation or changeset and records any required moderation/audit information in
  the same transaction.
- Move private query/load/insert functions before public APIs and document data
  sensitivity, pagination, target-not-found behavior, and audit side effects.

## Verification

- Test index/create separately for user/moderator/admin, missing/deactivated
  target slugs, invalid attrs, and audit behavior.
