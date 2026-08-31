# PollOptions SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 13 logical sites, including PollOptions CRUD and
changeset paths, poll-option preload paths, vote-count counter updates, the
poll-scoped staff voter listing, the moved poll loader, and topic/poll
association preloads.

## Changed shapes

### Staff voter option listing

- Master: `master:lib/philomena_web/controllers/topic/poll/vote_controller.ex:25-35`
  queried `poll_options` with fixed `poll_id = ?`, preloaded
  `poll_votes` and each vote's `user`, and selected all option columns; it
  then filtered `vote_count > 0` in application memory. There was no
  `ORDER BY`.
- context-logic: `lib/philomena/poll_votes.ex:49-59` performs the same
  poll-scoped `poll_options` collection query and the same `poll_votes -> user`
  preload, but adds SQL predicate `vote_count > 0`. There is still no
  `ORDER BY`.
- Delta: `vote_count > 0` moved from an in-memory filter into the final SQL
  `WHERE`; joins/preloads, pagination, grouping, and ordering are unchanged.
  This is `changed, index-relevant` because a predicate was added, although
  the result is a small bounded set of options per poll.
- Index status: covered; no index action
- Evidence: the existing unique
  `index_poll_options_on_poll_id_and_label (poll_id, label)` supplies a
  B-tree path for the equality prefix `poll_id = ?`; the remaining
  `vote_count > 0` is evaluated against the per-poll rows. `poll_votes` has
  unique `(poll_option_id, user_id)` and the option foreign key is the
  preload join key. No representative plan or workload evidence supports a
  separate `(poll_id, vote_count)` index for a poll containing at most 20
  options.
- Confidence: high

### Vote-count counter updates

- Master: `master:lib/philomena/poll_votes.ex:92-100` incremented
  `poll_options.vote_count` with `UPDATE ... WHERE id IN (?)`; the deletion
  path at `master:lib/philomena/poll_votes.ex:194-201` decremented one row
  with `WHERE id = ?`, selected its `poll_id`, and returned that value to the
  following poll-counter update.
- context-logic: `lib/philomena/poll_options.ex:44-54`, composed by
  `lib/philomena/poll_votes.ex:105-109` and `:151-156`, issues
  `UPDATE poll_options SET vote_count = vote_count + ? WHERE id IN (?) AND
poll_id = ?` for both increment and decrement branches. The parent poll is
  locked before this step.
- Delta: the option update gained the parent-scope predicate `poll_id = ?`
  and the deletion path no longer performs a separate `RETURNING`-style
  `select poll_id` update result. The added parent predicate is a semantic
  correctness guard against changing an option outside the loaded poll; the
  lookup remains primary-key driven. This is `changed, index-relevant` by the
  plan's write-predicate rule, but not an index candidate.
- Index status: covered; no index action
- Evidence: `poll_options_pkey (id)` covers the `id IN (?)`/`id = ?` target;
  the added `poll_id` check is residual validation after the primary-key
  lookup. Both structure dumps retain this primary key and the same
  `index_poll_options_on_poll_id_and_label (poll_id, label)`. No EXPLAIN was
  needed because the target is identified by a unique primary key.
- Confidence: high

## Unchanged or non-index-relevant sites

- Poll-scoped option preloads are shape-equivalent. The master poll edit
  controller's `Repo.preload(conn.assigns.poll, :options)` at
  `master:lib/philomena_web/controllers/topic/poll_controller.ex:39-42`
  and the master vote flow's option-id query at
  `master:lib/philomena/poll_votes.ex:133-138` are represented by
  `Philomena.Polls.load_topic_poll/1` at `lib/philomena/polls.ex:34-39`
  (preloading `:options`) and `Philomena.PollOptions.load_options/1` at
  `lib/philomena/poll_options.ex:25-30`. The association preload is a
  `poll_options` read filtered by the parent poll ID; the current function
  reuses already-preloaded options in the main vote/edit paths. The old
  option-ID query selected only `id`, while the preload selects option rows;
  that projection change is not an access-path change. The existing
  `(poll_id, label)` index covers the parent equality.
- The topic page's `poll: :options` preload at
  `lib/philomena/topics.ex:301` is the moved/centralized equivalent of the
  old poll display loading path. It issues the ordinary association preload
  for `poll_options` by `poll_id`; no association `where` clause exists in
  `Polls.Poll` at `lib/philomena/polls/poll.ex:10-12`, and no SQL predicate or
  ordering changed.
- `Polls.load_topic_poll/1` at `lib/philomena/polls.ex:34-39` is the moved
  counterpart of `master:lib/philomena_web/plugs/load_poll_plug.ex:9-18`:
  both load one `polls` row by `topic_id = ?`. Its additional `:options` and
  `topic: :forum` preloads are query composition changes owned by Polls and
  shared follow-up, not a new PollOptions index requirement.
- `PollOptions.PollOption` at `lib/philomena/poll_options/poll_option.ex:10-16`
  has `belongs_to :poll` and `has_many :poll_votes` with no `where`,
  `order_by`, or custom join clause in either ref. `Polls.Poll.options` adds
  `on_replace: :delete` only; it does not alter preload SQL. The creation
  changeset's unique constraint at `:25-32` uses the existing unique
  `(poll_id, label)` index and does not change a row-selection predicate.
- Poll-option inserts, loaded-row updates/deletes, and changeset-only paths in
  `master:lib/philomena/poll_options.ex:38-102` have no changed lookup
  predicate in context-logic; their removal is API ownership cleanup. No
  live callers of the old standalone CRUD functions were found in either ref.
- The `poll_votes` -> `user` association preload used by the staff listing
  remains the same follow-up query shape. Its ownership and any shared
  authorization/loader details belong to the PollVotes/shared audit.

## New, deleted, moved, or ambiguous sites

- `master:lib/philomena/poll_options.ex:20-22` (`list_poll_options/0`) and
  the standalone `get_poll_option!/1`, create, update, delete, and changeset
  functions were deleted. No repository callers were found; the former
  unfiltered collection read had no reliable live workload counterpart and
  is not an index recommendation.
- The old vote-controller option listing moved to
  `Philomena.PollVotes.list_votes/3`; it is reported above because it is a
  PollOptions-table query whose final shape changed. The old poll plug and
  controller preload moved into Polls/Topics services and are linked above.
- Poll option ordering is unchanged and remains unspecified at SQL level:
  neither `has_many :options` association has `order_by`, and neither the
  option preload nor staff listing adds `ORDER BY`. Result ranking is done in
  memory by `PhilomenaWeb.Topic.PollView.ranked_options/1` using
  `vote_count DESC, id ASC`. The edit/vote form's raw `poll.options` order is
  therefore not guaranteed by PostgreSQL; this is a pre-existing ordering
  correctness concern, not a context-logic shape delta or index candidate.
- No ambiguous PollOptions query site remained after tracing the complete
  `master..context-logic` diff and all current/old `PollOption` references.

## Follow-ups

- Link the Polls/PollVotes parent loader and nested `poll_votes -> user`
  preload findings from their owning reports; no `shared.md` entry was added
  here.
- No PollOptions index candidate remains. Existing coverage is
  `poll_options_pkey`, unique `(poll_id, label)`, and the existing PollVotes
  unique `(poll_option_id, user_id)` plus `user_id` index.
- No read-only EXPLAIN was run: the only changed reads are bounded by a poll,
  and the changed writes target primary-key rows. The source/schema audit is
  complete without database-container evidence.
