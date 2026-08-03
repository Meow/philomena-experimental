# Notifications context plan

Source: `lib/philomena/notifications.ex`; consumers: notification list/category
controllers and channel/forum/topic/gallery/image event producers.

## Findings

- User reads take Actor but immediately use `actor.user`; anonymous behavior and
  self-only authorization are implicit. `category_for_param/1` is public parsing
  logic with a separate failure convention.
- Six create and six clear functions expose event-specific persistence directly.
  They are service APIs, but their idempotency, transaction boundary, and caller
  authorization assumptions are barely documented.
- Only one private helper appears at the end, so layout and docs/spec coverage do
  not match the requested convention.

## Work

- Make unread/count/category APIs explicitly actor-scoped: anonymous actors are
  unauthorized or return an intentional empty result, and no caller can select a
  different user.
- Normalize category parsing to `{:ok, category}`/`{:error, :not_found}` (or a
  named invalid-param error) so controllers do not maintain their own cases.
- Treat event creation/clearing as internal service APIs composed by the owning
  context transaction. Where feasible accept `Ecto.Multi`; otherwise document
  after-commit behavior and idempotency. Consolidate repeated event mechanics
  behind private generic functions without exposing polymorphic raw queries.
- Put private event/query/delete functions first and public reader/service APIs
  afterward. Add typespecs and examples for each retained public event function.

## Verification

- Test anonymous/user isolation, category parsing, pagination, duplicate event
  creation, idempotent clears, and rollback/after-commit coupling for every event
  kind.
