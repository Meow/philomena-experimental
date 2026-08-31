# Posts SQL shape audit

Refs: master -> context-logic
Status: complete

Query sites inspected: 27 owned Posts/Versions sites, plus moved topic-page
callers, report-target callers, profile/search preloads, and the shared forum
transaction workflow.

## Changed shapes

### Route-scoped post loads and moderation locks

- Master: `lib/philomena_web/plugs/load_post_plug.ex:16-19`, the JSON topic
  controller's `show_post/3`, and loaded-struct mutation functions in
  `lib/philomena/posts.ex`; the common read was `posts WHERE topic_id = ? AND
id = ?` (or `posts WHERE id = ?`), with a preload. The JSON route additionally
  joined `topics` and `forums` and filtered topic slug/hidden state and forum
  access/name.
- context-logic: `Philomena.Posts.load_post_in_topic/4` (`posts.ex:39-46`),
  `show_post/2` (`posts.ex:183-195`), and
  `Philomena.Forums.TransactionWorkflow.put_forum_and_topic_and_post_locks/8`
  (`forums/transaction_workflow.ex:279-328`). A topic-scoped read is
  `posts WHERE topic_id = ? AND id = ?` plus the actor-dependent
  `available_posts` predicates; a global read is `posts WHERE id = ?` plus the
  same availability predicates. The lock path is three `FOR UPDATE` lookups:
  `forums WHERE short_name = ?`, `topics WHERE slug = ? AND EXISTS (forums
WHERE topic.forum_id = forum.id)`, and `posts WHERE id = ? AND EXISTS (topics
WHERE post.topic_id = topic.id)`, with `topic:forum`/user preloads.
- Delta: parent scoping and visibility/availability predicates are now part of
  the Posts read and mutation lookup; moderation mutations now lock the
  route's forum, topic, and post before updating by primary key. This is both
  an index-relevant shape change and a correctness hardening (wrong-topic IDs
  no longer address a post).
- Index status: covered; no new Posts index action.
- Evidence: `posts_pkey` covers `id`; `index_posts_on_topic_id_and_created_at`
  and the unique `index_posts_on_topic_id_and_topic_position` cover topic
  equality and topic-position access; `forums.short_name` and `topics.slug`
  are covered by their existing unique indexes. The correlated `EXISTS` checks
  join through primary/foreign-key columns and do not identify a missing
  Posts access path.
- Confidence: high

### Post creation max-position lookup

- Master: `Philomena.Posts.create_post/3` (`master lib/philomena/posts.ex:69-76`):
  `posts WHERE topic_id = ? ORDER BY topic_position DESC LIMIT 1`.
- context-logic: shared helper
  `Philomena.Forums.TransactionWorkflow.put_max_topic_position/1`
  (`forums/transaction_workflow.ex:374-381`), used by `Posts.create_post/4`
  and topic creation. The normalized shape is unchanged.
- Delta: moved/composed into a lock-aware Multi step; no SQL shape change.
- Index status: covered; no index action.
- Evidence: unique `(topic_id, topic_position)` index supplies the equality and
  ordering path.
- Confidence: high

### Post last-pointer refresh after create/hide/restore

- Master: create wrote the just-created ID directly to the topic and forum;
  hide/restore called `Topics.update_topic_last_post_query/1` and
  `Forums.update_forum_last_post_query/1` as separate update-all queries.
- context-logic: `Topics.put_refresh_last_post/1` (called from Posts create,
  hide, and restore) uses `Topics.update_last_post_query/1`
  (`topics.ex:984-1001`): an `UPDATE topics WHERE id = ?` whose assignments
  are `max(posts.id) WHERE posts.topic_id = ? AND hidden_from_users IS FALSE`
  and `max(posts.created_at)` with the same predicate. Forum refresh is the
  corresponding shared helper used by the Posts workflows.
- Delta: the topic refresh changed from direct pointer assignment / the old
  helper shape to two correlated aggregate scans with a hidden-post predicate;
  it is index-relevant for repeated last-post refreshes. This also encodes a
  correctness change: hidden posts are excluded from cached last-post values.
- Index status: candidate, needs plan evidence.
- Evidence: `(topic_id, created_at)` supports the `max(created_at)` branch;
  `(topic_id, topic_position)` does not directly cover `max(id)`. There is no
  partial index on `(topic_id, id)` for `hidden_from_users IS FALSE` in the
  current `structure.sql`. A generic index recommendation is deferred because
  the aggregate/visibility workload and table cardinality were not measured.
- Confidence: medium

### Post history read

- Master: `Philomena.Versions.load_post_versions/1` (`versions.ex:38-48`),
  called by the history controller after `LoadPostPlug`: `post_versions WHERE
post_id = ? ORDER BY created_at DESC, id DESC LIMIT 26`, with user/award
  preloads.
- context-logic: `Philomena.Posts.list_post_history/4` (`posts.ex:769-774`)
  first performs the route-scoped post load above, then calls
  `Philomena.Versions.for_post/1`; `Versions.load_versions/3`
  (`versions.ex:70-81`) emits the same history query and preloads.
- Delta: authorization and route parent scope moved into the Posts context;
  the version SQL shape is unchanged. The write-side first-version existence
  check remains `post_versions WHERE post_id = ?`, now conditional on a
  meaningful edit, and snapshot inserts have no row-selection predicate.
- Index status: covered; no index action.
- Evidence: `post_versions_post_id_created_at_index (post_id, created_at)`
  covers the equality/order prefix; `post_versions_pkey` supplies the ID
  tie-breaker. `post_versions_user_id_index` covers the user preload lookup.
- Confidence: high

### User attribution wipe

- Master: no corresponding Posts query site.
- context-logic: `Philomena.Posts.wipe_user_attribution!/3`
  (`posts.ex:807-811`) batches `posts WHERE user_id = ?` and issues batched
  updates setting `ip` and `fingerprint`.
- Delta: new/unpaired maintenance workload introduced by the context move.
- Index status: covered; no index action.
- Evidence: `index_posts_on_user_id` covers the batch selection. The update
  target is selected by that indexed predicate and changes no lookup key.
- Confidence: high

### Search result SQL preloads

- Master: HTML/API search used OpenSearch (excluded from this audit), then
  SQL preloaded `:user, :topic` for API and `:deleted_by, topic: :forum,
user: [awards: :badge]` for HTML.
- context-logic: `Philomena.Posts.query_posts/3` (`posts.ex:221-239`) uses the
  same OpenSearch search definition and a single preload definition including
  deleted user, topic/forum, and user awards.
- Delta: OpenSearch request/filter bodies are out of scope; SQL preload
  associations are broader/unified. The association queries remain primary-key
  or foreign-key lookups and do not change the Posts row-selection access path.
- Index status: no index action.
- Evidence: Posts has existing `user_id` and `deleted_by_id` indexes; topic and
  forum association loads use primary/foreign-key coverage.
- Confidence: high

## Unchanged or non-index-relevant sites

- `Posts.Query` and `Posts.SearchIndex` are unchanged between refs; their
  OpenSearch-only behavior is excluded. `query_posts/3` preserves newest-first
  `created_at DESC` search ordering and pagination.
- `Posts.perform_reindex/2` retains `posts WHERE field(column) IN (?)` and the
  same indexing preloads. `reindex_post/1`, `reindex_posts_in_topic/1`, and
  `user_name_reindex/2` enqueue or issue OpenSearch work, not PostgreSQL query
  shapes (apart from the unchanged reindex preload in `perform_reindex/2`).
- `Posts.change_post/1`, changeset validation, and all inserts/updates whose
  row was already selected do not add a database row-selection predicate.
- `Versions.load_versions/3` ordering, limit, and user preloads are unchanged;
  `Versions.record_edit/5` changes transaction composition and result handling,
  not the `post_id` existence predicate or insert target.
- Post schema association declarations (`Post.belongs_to user/topic/deleted_by`
  and current `has_many :reports`) do not add an association `where` clause.
  `PostVersion.belongs_to post/user` likewise has no filtered association.
- `site_statistics.ex:141-142` retains first/last Post primary-key ordering
  queries and is supporting persistence ownership, not a Posts-context shape
  delta.

## New, deleted, moved, or ambiguous sites

- The old controller `LoadPostPlug` and inline JSON topic/post queries were
  deleted and paired with `Posts.load_post_in_topic/4`, `Posts.show_post/2`,
  and the shared lock workflow above. They are moved/rewritten counterparts,
  not unpaired omissions.
- Topic-page post loading moved from `PhilomenaWeb.TopicController.show/2`
  (`master:54-60`) into `Philomena.Topics.load_topic_posts/3`
  (`context-logic:74-87`). Its final SQL is `posts WHERE topic_id = ?` plus
  actor-dependent availability predicates and topic-position range bounds,
  `ORDER BY created_at ASC, id ASC`, and the same expanded preloads. Compared
  with master, visibility predicates and the `id` tie-breaker are new and
  index-relevant; the existing `(topic_id, topic_position)` unique index covers
  the range, while the requested created-at ordering is not fully covered by
  that index. This query is owned by Topics; record as a linked follow-up rather
  than proposing a duplicate Posts index.
- Topic page ID targeting moved from an unscoped `posts WHERE id = ?` lookup in
  `TopicController.show/2` to `Topics.topic_pagination/4`, which scopes by
  topic, applies availability, and authorizes the result. This is a correctness
  and shape change owned by Topics; the Posts route-load evidence above is the
  corresponding shared pattern.
- Report target loading moved from controller plugs to
  `Reports.new_report/2`/`create_report/3`, which call
  `Posts.load_report_target/4` (`posts.ex:796-800`). It uses the same scoped
  `load_post_in_topic/4` shape and is covered by the route-load finding.
- No required ref, schema, or database container was needed for this source
  audit. No EXPLAIN was run: the available workspace did not provide a
  representative PostgreSQL dataset, so the last-pointer candidate remains
  medium-confidence and requires runtime plan evidence.

## Follow-ups

- Shared helper follow-up: reconcile the last-post refresh SQL across Posts,
  Topics, Forums, and topic visibility workflows before any index change. The
  candidate, if plans/workload justify it, is a partial B-tree beginning
  `(topic_id, id)` with predicate `hidden_from_users IS FALSE`; validate it
  against the `max(created_at)` branch and write/storage cost first.
- Shared helper follow-up: `Forums.TransactionWorkflow` owns forum/topic/post
  lock query shapes used by Posts and Topics. Keep its canonical finding in
  `shared.md`; this report intentionally does not duplicate a shared report.
- Correctness follow-up for the coordinator: verify that availability and
  hidden/deleted semantics intended for each actor role match the former
  controller plug behavior, especially global `show_post/2` versus the
  parent-scoped route endpoints.
