# UserStatistics context plan

Source: `lib/philomena/user_statistics.ex`; consumers: activity-producing
contexts that increment daily user counters.

## Findings

- Four public `inc_stat` clauses form a loosely typed service API with no
  moduledoc, actor semantics, or documented allowed counters.
- The context is not controller-facing, but it owns atomic derived data and must
  not become an authorization bypass or accept arbitrary fields.
- Public clauses precede persistence detail by default and lack specs/examples.

## Work

- Define a finite statistic key type and one explicit service function accepting
  a loaded user (or user ID only for worker invariants). Reject unknown fields at
  compile/function-clause level rather than dynamic updates.
- State that authorization belongs to the successful owning action and compose
  increments into that action's Multi when consistency requires it. Define date/
  timezone, upsert, and retry/idempotency semantics.
- Put private upsert/query mechanics first, then the narrow documented service
  API. Consider event-specific names if increments need different transaction
  coupling.

## Verification

- Test day-boundary behavior in the configured timezone, concurrent increments,
  user deletion, invalid keys, and rollback with representative owning actions.
