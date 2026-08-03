# Polls context plan

Source: `lib/philomena/polls.ex`; consumers: nested topic poll edit/update
controller and PollVotes.

## Findings

- `load_poll_for_edit/3` and `update_poll/4` share a custom
  forum/topic/poll loader, but form/write prerequisites and action-specific
  authorization need review.
- Public `load_poll/1` accepts a loaded topic and bypasses actor authorization;
  raw active checks and lower-level update mechanics share the public surface.
- Poll membership is inherently nested under topic/forum, and all loaders must
  preserve that hierarchy.

## Work

- Make the actor-first forum/topic/poll loader the only request boundary. Query
  the poll by loaded topic ID; mismatched or absent polls are not-found, while a
  visible poll without edit permission is unauthorized.
- Apply `verify_write_access/1` to both edit and update and authorize distinct
  `:edit`/`:update` actions. Keep general poll viewing part of the Topic page API
  rather than an unguarded `load_poll/1`.
- Move raw loaded-topic poll lookup, changeset/update, and `active?` mechanics
  private unless PollVotes needs a narrow documented service function.
- Reorder and document option replacement, existing-vote constraints, close
  time/timezone handling, and transaction behavior.

## Verification

- Test restricted/hidden forum/topic, absent/mismatched poll, edit/update parity,
  option changes after votes, invalid close times, and active boundary times.
