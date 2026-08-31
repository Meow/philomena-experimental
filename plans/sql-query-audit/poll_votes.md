# PollVotes SQL shape audit

Refs: master -> context-logic  
Status: complete

Query sites inspected: 12 (PollVotes queries, moved controller query, nested
association preloads, and Polls/PollOptions helpers used by PollVotes)

## Changed shapes

### Staff vote listing (`list_votes/3`)

- Master: `PhilomenaWeb.Topic.Poll.VoteController.index/2` queried
  `poll_options` with `poll_id = ?`, preloaded `poll_votes -> user`, then
  filtered `vote_count > 0` in Elixir.
- context-logic: `Philomena.PollVotes.list_votes/3` queries
  `poll_options` with `poll_id = ? AND vote_count > 0`, then preloads
  `poll_votes -> user`.
- Delta: the `vote_count` predicate moved into the SQL collection relation;
  the base parent filter and association preload are unchanged. No ordering or
  pagination is requested.
- Index status: covered
- Evidence: `index_poll_options_on_poll_id_and_label (poll_id, label)` covers
  the leading parent equality; `index_poll_votes_on_poll_option_id_and_user_id`
  covers the poll-vote preload's foreign-key lookup. The extra `vote_count`
  predicate is not selective enough, on this bounded per-poll option
  collection, to justify an additional index without plan/workload evidence.
- Confidence: high

### Parent-scoped vote lookup (`load_poll_vote/2`, used by `delete_vote/4`)

- Master: `VoteController.load_poll_vote/1` parsed the ID and called
  `PollVotes.get_poll_vote/1`, yielding a `poll_votes` primary-key lookup with
  no poll parent predicate. The route's previously loaded topic/poll was not
  part of this query.
- context-logic: `Philomena.PollVotes.load_poll_vote/2` joins
  `poll_votes` to `poll_options` through `poll_vote.poll_option_id`, adds
  `poll_options.poll_id = ?`, and calls `Loader.fetch/2`, which adds the vote
  `id = ?` lookup and returns at most one row.
- Delta: the member lookup gains an inner association join and parent poll
  predicate, preventing a vote from another poll from being removed through
  this route. The lookup remains anchored by `poll_votes.id`.
- Index status: covered
- Evidence: `poll_votes_pkey (id)` covers the vote member lookup; the join uses
  the primary key of `poll_options` for `poll_votes.poll_option_id`, and
  `index_poll_votes_on_poll_option_id_and_user_id (poll_option_id, user_id)`
  also has the join column as its leading key. `poll_options.poll_id` is
  evaluated after the option row is found; the existing
  `index_poll_options_on_poll_id_and_label (poll_id, label)` covers that parent
  lookup if it is used as the driving relation.
- Confidence: high

### Vote-count option update (`PollOptions.put_vote_count_delta/5`)

- Master: the create path updated `poll_options` with
  `id IN (?)`; the delete path first selected `poll_id` by `id = ?`, then
  updated the same option by its loaded row.
- context-logic: the shared helper updates `poll_options` with
  `id IN (?) AND poll_id = ?` for both vote insertion and deletion.
- Delta: the update target gains a parent-scope equality predicate. This is a
  write target predicate and is index-relevant for classification, while also
  being a correctness guard against cross-poll option IDs.
- Index status: covered
- Evidence: `poll_options_pkey (id)` covers the option ID set; the existing
  `(poll_id, label)` index covers the parent key when that is the useful access
  path. The ID list is expected to be small and no plan evidence supports a
  new `(poll_id, id)` index.
- Confidence: high

### Poll lock used during vote creation and deletion

- Master: `create_poll_votes/3` locked `polls` with `id = ? FOR UPDATE`.
  Deletion did not issue a poll lock.
- context-logic: `create_votes/4` and `delete_vote/4` both compose
  `Multi.lock_one/3` over `polls WHERE id = ?`; the create lock preloads
  `topic -> forum` and the delete lock does not preload.
- Delta: creation retains the same primary-key lock shape, with added
  association preload SQL. Deletion adds a primary-key poll lock before
  deleting the vote and counter updates, supporting the transaction's
  concurrency invariant. The lock predicate itself is unchanged/covered.
- Index status: covered
- Evidence: `polls_pkey (id)` covers both row-lock lookups. The added create
  preload uses the existing topic primary key and forum route lookup paths.
- Confidence: high

## Unchanged or non-index-relevant sites

- `user_voted?/2` in `PollVotes` is relationally unchanged from master
  `voted?/2`: an existence query joining `poll_votes` to `poll_options` with
  `poll_options.poll_id = ? AND poll_votes.user_id = ?`. The aliases and
  context API changed, but the join, filters, and existence operation did not.
  The unique `(poll_option_id, user_id)` index covers the vote-side lookup;
  option primary keys and the `(poll_id, label)` index cover the association
  side. No new index action.
- `PollVotes` vote insertion remains an `INSERT ... poll_votes` batch with no
  row-selection predicate. The ballot validation in
  `PollVotes.Ballot.changeset/4` is in memory and issues no SQL.
- `Polls.put_total_votes_delta/4` is the moved equivalent of the master vote
  transaction's `UPDATE polls SET total_votes = ... WHERE id = ?`; it remains
  primary-key covered.
- `PollOptions.load_options/1` is a preload of `poll_options` by its
  `poll_id` association. It is used by vote creation; the SQL shape is
  unchanged in substance and is covered by the poll-id-leading unique index.
- `PollOption.has_many :poll_votes` and `PollVote.belongs_to :poll_option` /
  `belongs_to :user` retain the same association keys. Their preload queries
  are foreign-key lookups, covered by the existing poll-vote indexes.
- `Multi.delete(:poll_vote, poll_vote)` targets the loaded vote by primary key;
  changeset metadata and schema `@type` additions do not alter its predicate.
- Counter updates on `polls.id` and option IDs, plus `PollVote` insertion
  conflict/constraint enforcement, have no new caller-controlled filters or
  ordering requirements.

## New, deleted, moved, or ambiguous sites

- The generic master `get_poll_vote!/1`, `get_poll_vote/1`,
  `update_poll_vote/2`, `delete_poll_vote/1`, and `change_poll_vote/1` APIs are
  deleted from the live context. Their generic member/update/delete behavior
  has no current caller in the inspected application paths; route deletion is
  represented by the parent-scoped `load_poll_vote/2` and `delete_vote/4`
  findings above.
- Master controller-owned poll-option listing and vote-ID loading moved into
  `PollVotes`; both are paired above rather than treated as wholly new work.
- `Polls.load_topic_poll/1` is a shared cross-context parent poll lookup used
  by PollVotes. Its `polls.topic_id = ?` lookup and option/topic/forum
  preloads are owned by the Polls audit; coordinate there rather than creating
  a duplicate PollVotes index finding.
- Forum/topic authorization and visibility queries invoked before each
  PollVotes operation are owned by the Forums/Topics audits and are not
  duplicated here.

## Follow-ups

- Reconcile the canonical `Polls.load_topic_poll/1` and
  `PollOptions.put_vote_count_delta/5` findings with the shared/coordinator
  reports. No `shared.md` or `summary.md` was created by this context audit.
- No representative `EXPLAIN (FORMAT JSON)` was run; the available source and
  structure evidence is sufficient for the covered PK/FK paths, while any
  index on `vote_count` or a composite option-ID/parent key would require
  representative workload and plan evidence.
