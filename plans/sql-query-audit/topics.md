# Topics SQL shape audit

Refs: master -> context-logic  
Status: complete

Query sites inspected: 12 owned sites/operation families, including the
complete `master..context-logic` Topics and moved web/API caller diff, topic
schema, topic preloads, and topic-owned transaction updates.

## Changed shapes

### Homepage topic strip (`list_front_page_topics/2`)

- Master: `lib/philomena_web/controllers/activity_controller.ex:78-87`.
  Collection on `topics`, inner join `forums` on `forums.id = topics.forum_id`,
  fixed `topics.hidden_from_users = false`, `forums.access_level = 'normal'`,
  title `!~ 'NSFW'`, `ORDER BY topics.last_replied_to_at DESC`, `LIMIT 6`, and
  forum/last-post-user preloads.
- context-logic: `lib/philomena/topics.ex:123-132`.
  Paginated collection on `topics`, inner join to the actor-dependent
  `Visibility.visible_forums/2` subquery on `forum_id`, actor-dependent
  `Visibility.visible_topics/2` (no hidden predicate for staff), title
  `!~ 'NSFW'`, `ORDER BY last_replied_to_at DESC`, pagination `LIMIT/OFFSET`,
  and forum/last-post-user preloads. The query is called by
  `lib/philomena/activities.ex:100`.
- Delta: changed forum access predicate/branching, hidden-topic predicate
  branching, and fixed `LIMIT 6` to a Scrivener collection page with count and
  offset. The SQL was moved from the homepage controller into Topics.
- Index status: needs plan evidence
- Evidence: `priv/repo/structure.sql` (same in both refs) has ordinary indexes
  on `topics.last_replied_to_at`, `topics.hidden_from_users`, and
  `topics.forum_id`; no composite index combines the visibility/join columns
  with the requested order. The access subquery is role-dependent and the
  title regex is not a generic B-tree workload. No representative EXPLAIN was
  run, so no index is recommended from source inspection alone.
- Confidence: high

### Parent-scoped topic member loads (`show_forum_topic/4` and callers)

- Master: `lib/philomena_web/plugs/load_topic_plug.ex:14-22`, plus the API
  loaders in `lib/philomena_web/controllers/api/json/forum/topic_controller.ex:23-31`
  and `.../topic/post_controller.ex:63-68`. The common route shape joined
  `topics` to `forums` and filtered `topic.slug`, `topic.hidden_from_users =
false`, `forum.short_name`, and `forum.access_level = 'normal'`; the web plug
  then preloaded user/forum/deletion/lock/poll associations.
- context-logic: `lib/philomena/topics.ex:222-226`, used by show, subscribe,
  read, hide/restore, move, stick/unstick, lock/unlock, update-title, and the
  topic page. It selects `topics` with equality predicates `forum_id = ?` and
  `slug = ?`, preloads user/forum, then authorizes the loaded row. The forum is
  separately loaded by `Forums.show_forum/2`; transaction lock variants are in
  the shared `Philomena.Forums.TransactionWorkflow`.
- Delta: changed from a joined lookup with SQL access/visibility predicates to
  a parent-scoped `(forum_id, slug)` lookup followed by application
  authorization. This is index-relevant in shape, while the removal of the
  hidden predicate is also a deliberate correctness/authorization semantic
  change for moderator and unsubscribe/mark-read branches.
- Index status: covered
- Evidence: unique `index_topics_on_forum_id_and_slug` is a B-tree on
  `(forum_id, slug)` and exactly covers the current lookup. The forum lookup is
  covered by the forum short-name unique index (owned by Forums/shared).
- Confidence: high

### Topic-page post pagination (`topic_pagination/4` and `load_topic_posts/3`)

- Master: HTML `lib/philomena_web/controllers/topic_controller.ex:45-60`
  looked up a jump post by primary key without topic scope, then selected
  `posts` by `topic_id` and a `topic_position` range, ordered by
  `created_at ASC`, and preloaded deleted-by/topic/forum/user-awards. The API
  `lib/philomena_web/controllers/api/json/forum/topic/post_controller.ex:19-31`
  selected by `topic_id`, `destroyed_content = false`, topic-position range,
  ordered by `topic_position ASC`, and preloaded the user.
- context-logic: `lib/philomena/topics.ex:57-87` scopes the jump-post lookup
  by `topic_id`, applies `Visibility.available_posts/2` and authorization, and
  selects page posts by `topic_id`, actor-dependent availability, two
  `topic_position` bounds, `ORDER BY created_at ASC, id ASC`, and the combined
  preloads. Both HTML and API callers use `show_topic_page/5`.
- Delta: added actor-dependent `destroyed_content`/approval/owner predicates,
  scoped the jump lookup to the loaded topic, changed the API ordering from
  `topic_position` to `created_at`, and added deterministic `id` tie-breaking;
  preload/result assembly was centralized. These are index-relevant changes.
- Index status: covered
- Evidence: `index_posts_on_topic_id_and_created_at` exists in
  `priv/repo/structure.sql` in both refs and supports the current equality plus
  ordering path. The position bounds and OR availability predicates may still
  require a different plan, but source/schema evidence does not justify a new
  generic index; no EXPLAIN was run.
- Confidence: high

### Topic last-post cache refresh (`put_refresh_last_post/2`)

- Master: `lib/philomena/topics.ex:337-347` exposed an update query on
  `topics.id = ?` setting `last_post_id` to `max(posts.id)` for the topic where
  `posts.hidden_from_users IS FALSE`. Creation separately updated the same row
  by primary key and set the inserted post id/time (`master` lines 60-64).
- context-logic: `lib/philomena/topics.ex:915-1001` uses an update-all on
  `topics.id = ?`, setting `last_post_id` to the same hidden-post max and also
  setting `last_replied_to_at` to `max(posts.created_at)` for the topic. It is
  invoked after topic/post visibility and creation workflows.
- Delta: added a second correlated aggregate (`max(created_at)`) and moved the
  update into the composable Multi workflow; the row-selection predicate
  remains the topic primary key.
- Index status: covered
- Evidence: topic lookup/update uses the primary key. The existing
  `index_posts_on_topic_id_and_created_at` supports the new `topic_id` plus
  `created_at` aggregate path; the hidden boolean remains a residual filter.
  The existing `posts.topic_id` foreign-key index/path covers the max-id
  subquery sufficiently absent plan evidence.
- Confidence: medium

### Topic post-count cache update (`put_post_visibility_counters/2`)

- Master: no standalone Topics query; post workflows used direct counter and
  last-post steps in the old context/callers.
- context-logic: `lib/philomena/topics.ex:970-981` adds an update-all on
  `topics.id = ?` with `post_count += ?`, used after post visibility changes.
- Delta: new/unpaired write workload introduced by transaction composition;
  row selection is by primary key and does not alter access requirements.
- Index status: covered
- Evidence: the topic primary key covers the update predicate.
- Confidence: high

## Unchanged or non-index-relevant sites

- Topic creation insert and title/hidden/sticky/lock/unlock/move updates in
  `lib/philomena/topics.ex:369-405`, `474-641`, `666-892` retain primary-key
  row targeting for the topic mutation. Their surrounding forum/topic lock
  queries are shared workflow sites, linked below; counter writes target
  primary keys. No separate index action follows.
- `lib/philomena/topics.ex:877-892` (`update_topic/4`) is the moved title
  update: it now loads by `(forum_id, slug)` and updates by topic primary key;
  the changeset only changes title and leaves slug intact. The lookup is
  covered by the unique composite index; the write is unchanged in access
  shape.
- `lib/philomena/topics.ex:301` topic-page `Repo.preload/2` for user, forum,
  deleted-by, locked-by, poll, and poll options is equivalent to the old plug's
  final preload set. The schema associations in `topics/topic.ex:17-24` have no
  association `where` clauses, so no hidden additional query shape exists.
- `lib/philomena/topics.ex:164-204` subscription operations use the shared
  subscription persistence helper after the same topic member lookup. The
  topic/user uniqueness and deletion queries are shared follow-ups, not a new
  Topics-owned SQL shape.
- `lib/philomena/topics.ex:1013-1016` notification clearing remains delegated
  to Notifications and has no Topics-owned query definition.
- `lib/philomena/topics/move_form.ex` is an embedded validation form only and
  creates no SQL.

## New, deleted, moved, or ambiguous sites

- `master:lib/philomena/topics.ex:get_topic!/1` was deleted without a reliable
  current public counterpart. It was a bare primary-key member lookup and has
  no index implication; callers were migrated to context-facing, authorized
  route operations or other owning contexts.
- The old homepage topic query moved to `Topics.list_front_page_topics/2` and
  is now called by `Activities`; it is classified above rather than counted as
  a duplicate Activities query.
- The old `LoadTopicPlug` and API topic loaders were deleted/moved into
  `show_forum_topic/4` and `show_topic_page/5`; the old and new post branches
  are both classified above.
- `Philomena.Forums.TransactionWorkflow` supplies the forum/topic row-lock
  queries used by Topic hide/restore/create/move and related post workflows.
  Those shared helpers are not duplicated here; see the shared audit follow-up.
- Runtime SQL generation and `EXPLAIN (FORMAT JSON)` were unavailable/not run
  in this source-only audit. The report therefore records existing index
  coverage and marks the homepage composite-order question as needing plan
  evidence rather than proposing an unsupported index.

## Follow-ups

- Link to the canonical shared audit for `Forums.TransactionWorkflow` lock
  queries, authorization/visibility helpers, subscription helpers, and
  notification clearing. In particular, reconcile the current two-step forum
  authorization plus topic lookup with the old joined normal-forum predicate.
- Validate the homepage page/count query and the post-page availability OR
  predicates with representative `EXPLAIN` plans on production-like data.
- Correctness review: `show_forum_topic/4` intentionally loads hidden topics
  before `authorize/3` for moderator and personal unsubscribe/read actions, but
  the changed API behavior should be covered by authorization tests. The old
  API post ordering was `topic_position`; the current shared page filters by
  `topic_position` but orders by `created_at, id`. The focused production review
  says the page must order ascending `topic_position`; treat this as a
  correctness/presentation fix before merge, not an index recommendation.
