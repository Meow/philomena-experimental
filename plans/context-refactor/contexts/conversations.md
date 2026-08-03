# Conversations context plan

Source: `lib/philomena/conversations.ex`; consumers: conversation/message,
read/hide/report, and message approval controllers.

## Findings

- `create_conversation_from/2` assumes map params and crashes otherwise; listing
  can raise a cast error from malformed query params.
- Conversation loading authorizes a possibly `nil` result before checking
  presence, creating the same role-dependent absent result as Loader.
- New-conversation uses `verify_not_banned/1`; create and message writes use
  `verify_write_access/1`. `create_message/3` has a TODO asking to return the
  message changeset rather than losing validation detail.
- Read/hide state, count helpers, raw message creation, and controller APIs are
  interleaved; approval has another custom ID/load/auth `else` block.

## Work

- Replace slug and message ID loading with shared safe query-based loaders:
  fetch a real conversation visible to the actor, and scope a message to it when
  the route provides both. Missing is always not-found.
- Normalize params before changeset/query compilation. Non-map create input and
  invalid listing filters return a changeset/query error suitable for the
  controller instead of raising.
- Require `verify_write_access/1` for the new form as well as create/message
  writes. Encode participant/admin visibility through abilities without passing
  only `actor.user` at public boundaries.
- Return the actual message changeset on validation failure. Give conversation
  creation a named result or stable multi result rather than translating errors
  in controllers.
- Make raw creation/state/count helpers private where they are only composition
  steps; retain documented notification/service APIs only for real external
  callers. Reorder and document transaction/email/notification behavior.

## TODO resolution

- Gracefully handle non-map create params.
- Convert list cast failures into an explicit query error.
- Return message changesets on validation failure.

## Verification

- Cover malformed params/filters/IDs, absent conversations, nonparticipants,
  deactivated recipients, repeated read/hide operations, message validation,
  approval scoping, and form/write prerequisite parity.
