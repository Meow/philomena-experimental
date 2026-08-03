# Channels context plan

Source: `lib/philomena/channels.ex`; consumers: channel display/admin,
subscription, and read controllers plus the automatic updater.

## Findings

- TODOs question why visit/subscribe/unsubscribe can be unauthorized and whether
  subscription insertion can fail. Those questions indicate the public contract
  and database invariants are not aligned.
- `clear_notification/2` parses IDs separately while other member paths use a
  private loader. Subscription authorization is currently expressed as `:show`
  on the channel, not as explicit subscribe/unsubscribe actions.
- Raw channel creation/state update and notification helpers remain public, and
  private loading/logging is interleaved with controller functions.

## Work

- Define explicit abilities for visit/read, subscribe, unsubscribe, and admin
  CRUD. If the desired rule is “any authenticated user who can see the channel,”
  encode that once in Ability rather than treating unauthorized as impossible.
- Route every ID operation, including notification clearing, through the shared
  safe loader. Require `verify_write_access/1` for subscription mutations if all
  writes share that prerequisite; keep read marking consistent with the chosen
  global policy.
- Make subscribe idempotent with a documented success value; preserve genuine
  database errors instead of claiming insert failure is impossible. Make
  unsubscribe idempotency equally explicit.
- Separate updater/service APIs from controller APIs; hide raw CRUD/state and
  notification helpers behind private functions where possible. Reorder the
  module and rewrite placeholder docs.

## TODO resolution

- Replace all three “why unauthorized?” TODOs with tested named abilities.
- Replace the insert-failure TODO with an idempotent conflict contract plus a
  test for unexpected persistence errors.

## Verification

- Cover hidden/offline/NSFW channels, anonymous and signed-in subscriptions,
  malformed/missing IDs, repeated toggles, notification clearing, and admin CRUD
  action distinctions.
