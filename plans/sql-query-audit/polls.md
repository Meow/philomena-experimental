# Polls SQL shape audit

Refs: master -> context-logic  
Status: complete
Query sites inspected: 8 (current `Philomena.Polls` query/preload/update sites, the master context API, and moved poll-loading callers)

## Changed shapes

### Parent-scoped poll loading (`load_topic_poll/1`)

- Master: `lib/philomena/polls.ex:list_polls/0` issued an unscoped `SELECT` from `polls`; the route-specific poll was loaded by `lib/philomena_web/plugs/load_poll_plug.ex` and its callers, with the topic relationship already established by the loader chain.
- context-logic: `lib/philomena/polls.ex:load_topic_poll/1` issues a member lookup on `polls` with `topic_id = ?`, preloading options and `topic -> forum`, through `Loader.one/1`.
- Delta: the generic CRUD listing/API was removed from the live context surface and the route operation is now a topic-scoped poll lookup with association preloads. The parent scope is a semantic/correctness improvement; the preload SQL adds `poll_options.poll_id IN (...)` and the topic/forum member lookups.
- Index status: covered
- Evidence: `polls_pkey (id)` covers the member/lock branch and `index_polls_on_topic_id (topic_id)` covers the parent lookup. `index_poll_options_on_poll_id_and_label (poll_id, label)` covers the option preload's leading equality column. No ordering is requested.
- Confidence: high

### Poll update lock (`update_poll/4`)

- Master: `lib/philomena/polls.ex:update_poll/2` updated the already-loaded poll; the old route loader supplied the member row, and no additional poll lookup was performed in this function.
- context-logic: `lib/philomena/polls.ex:poll_query` selects `polls` by `id = ?`, preloads options and topic/forum, and `Multi.lock_one/3` applies the row lock before the update.
- Delta: the update operation adds an explicit primary-key lookup/lock and association preloads inside the transaction. The row-selection predicate is the primary key; the added preloads do not introduce an uncovered access path.
- Index status: covered
- Evidence: `polls_pkey (id)`; option preload covered by the existing poll-id-leading unique index.
- Confidence: high

### Total-vote counter update (`put_total_votes_delta/4`)

- Master: `lib/philomena/poll_votes.ex:update_poll_votes_count/3` performed `UPDATE polls SET total_votes = ... WHERE id = ?`.
- context-logic: `lib/philomena/polls.ex:put_total_votes_delta/4` performs the same row-targeted update through `Philomena.Multi`.
- Delta: ownership and transaction composition moved; the `WHERE id = ?` shape is unchanged.
- Index status: no index action
- Evidence: `polls_pkey (id)` covers the update target.
- Confidence: high

## Unchanged or non-index-relevant sites

- The old `active?/1` existence query on `polls.id = ? AND active_until > ?` is replaced by `active?/2`, which evaluates the already-loaded poll in memory. This removes a database existence workload; it is not an index candidate. The retained poll member lookup is PK-covered.
- The poll changeset and `on_replace: :delete` association behavior do not themselves change a row-selection predicate. Insert/update association writes use the existing foreign-key/unique constraints.
- Current callers in `Topics` and `PollVotes` use `load_topic_poll/1`; these are the same canonical parent-scoped shape and are linked to the shared/cross-context findings rather than duplicated here.

## New, deleted, moved, or ambiguous sites

- The generated generic `list_polls/0`, `get_poll!/1`, create, delete, and change functions present on master are no longer exposed on context-logic. No live caller was found for the generic list/member functions; the route workload is represented by `load_topic_poll/1` and the topic loader/preload path.
- The poll route edit/update operations moved from controller/plug-owned loading into `Philomena.Polls`; the query shape is classified above. Authorization and forum/topic visibility queries are owned by Forums/Topics/shared findings.

## Follow-ups

- Coordinate with the Topics and PollVotes reports for the canonical `load_topic_poll/1` preload and poll-lock findings.
- No representative EXPLAIN was necessary: all changed row lookups are primary-key or existing foreign-key-leading access paths, and poll option collections are bounded by the poll's small option set.
