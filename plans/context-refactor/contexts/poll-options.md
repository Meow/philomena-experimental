# PollOptions context plan

Source: `lib/philomena/poll_options.ex`; aggregate owner: `Philomena.Polls` and
`Philomena.PollVotes`.

## Findings

- The module is generic generated CRUD, including a public
  `get_poll_option!/1`, but poll options are nested children and never an
  independent controller resource.
- Raw option IDs must always be constrained to the poll/topic/forum route; this
  module currently provides no actor or parent boundary.

## Work

- Inventory callers and make generic list/get!/CRUD/change functions private or
  fold them into Polls. Retain only narrow loaded-poll transaction functions if
  cross-module composition with PollVotes requires them.
- Remove the bang loader. Any option locator must safely parse and query by both
  poll ID and option ID before the owning Polls/PollVotes authorization.
- Document option-order and deletion/vote constraints for retained service APIs;
  keep persistence helpers before that surface.

## Verification

- Test option persistence/order invariants here and malformed/missing/wrong-poll
  option IDs through Polls/PollVotes controller APIs.
