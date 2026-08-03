# PollVotes context plan

Source: `lib/philomena/poll_votes.ex`; consumer: nested topic poll-vote
controller.

## Findings

- Poll/topic/forum loading delegates partly to Topics, while vote and option IDs
  use local loaders/parsers. A TODO proposes replacing option-ID filtering with
  Loader.
- `list_votes`, create, and delete have different preconditions and visibility
  concerns; raw `create_poll_votes/…` remains public above controller APIs.
- `parse_option_id/1` filters malformed choices but does not itself prove each
  option belongs to the loaded poll.
- Multiple `voted?/2` clauses accept loose actor/user shapes without an explicit
  public convention.

## Work

- Use the forum/topic/poll parent loader from Polls/Topics, then safely load every
  selected option with a query scoped to that poll. Reject the entire submission
  with a changeset error for malformed, missing, duplicate, or wrong-poll option
  IDs; never silently drop choices.
- Apply `verify_write_access/1` and action-specific vote authorization to create
  and delete. Authorize vote listing separately because voter identity may be
  private while aggregate results are public.
- Replace the option parser TODO with the shared safe locator/scoped query. Make
  raw vote creation and ID loading private.
- Standardize `voted?` on Actor at the public edge and hide user/nil clauses.
  Reorder private loaders/validators/transactions before public APIs and document
  multi-select, active/closed poll, replacement, and anonymity behavior.

## Verification

- Cover malformed/missing/wrong-poll/duplicate options, inactive polls,
  anonymous and banned/no-fingerprint writes, vote replacement/deletion, result
  privacy, and forum/topic visibility.
