# Versions SQL shape audit

Refs: master -> context-logic
Status: complete

--- status ---

Query sites inspected: 11 distinct Versions query sites/branches, including
the post and comment history reads, edit existence/inserts, both legacy
backfill statements, the empty-target guards, version schemas, migration
history, and the moved history callers.

No new or modified relational SQL shape was found; the only SQL delta is that
the current no-op-edit branch suppresses the existing version queries.

## Changed shapes

### `record_edit` meaningful-edit branch and Multi integration

- Master: `lib/philomena/versions.ex:62-89`, called by the post and comment
  update `Multi.run` steps in `lib/philomena/posts.ex:154-163` and
  `lib/philomena/comments.ex:88-98`. For either version table, it checks
  `WHERE <post_id|comment_id> = ?`, conditionally inserts the initial row, and
  inserts the edited snapshot. The snapshot insert has no row-selection
  predicate.
- context-logic: `lib/philomena/versions.ex:60-68,139-159`, called by
  `lib/philomena/posts.ex:409-428` and `lib/philomena/comments.ex:502-522`.
  `meaningful_edit?/2` runs before the same existence check and inserts; when
  both body and edit reason are unchanged, no version-table SQL is issued.
- Delta: the meaningful branch has the same equality lookup predicate and the
  same insert targets. The no-op branch deletes the old existence check and
  both inserts from that workload. `insert!` versus `insert`, actor/Multi
  plumbing, and value normalization do not alter PostgreSQL row selection.
- Index status: no index action
- Evidence: `post_versions_post_id_created_at_index (post_id, created_at)`
  and `comment_versions_comment_id_created_at_index (comment_id, created_at)`
  both cover the equality existence lookup. Inserts do not need a lookup
  index. The changed branch reduces write/read frequency rather than adding an
  access path.
- Confidence: high

## Unchanged or non-index-relevant sites

- `Philomena.Versions.for_post/1` and `for_comment/1` in
  `lib/philomena/versions.ex:70-80,95-112` are the renamed counterparts of
  master's `load_post_versions/1` and `load_comment_versions/1` at
  `lib/philomena/versions.ex:29-49`. The normalized read shapes are unchanged:
  `post_versions` or `comment_versions`, equality on the owning foreign key,
  `ORDER BY created_at DESC, id DESC`, `LIMIT 26`, followed by the same
  `user -> awards -> badge` preload chain. The result still drops the oldest
  row after pairing it as the diff base, so the newest-first history ordering
  is unchanged.
- The history-read parent is now loaded and authorized by `Posts.list_post_history/4`
  (`lib/philomena/posts.ex:769-773`) and
  `Comments.list_comment_history/3` (`lib/philomena/comments.ex:555-563`),
  instead of the old web loaders in
  `lib/philomena_web/controllers/topic/post/history_controller.ex:23-26` and
  `lib/philomena_web/controllers/image/comment/history_controller.ex:17-20`.
  This is query ownership/movement; the Versions query begins from an already
  loaded parent and has the same shape.
- `Philomena.Versions.LegacyBackfill` has identical SQL in both refs:
  `initial_rows/1` (`lib/philomena/versions/legacy_backfill.ex:64-77`),
  `shifted_edit_rows/1` (`:84-102`), and `ensure_empty!/0` (`:104-113`). The
  `DISTINCT ON (item_id)` ordering, window partition/order, parent and user
  joins, item-type predicates, and target-table insert columns are unchanged.
  The current-only change is documentation retaining the legacy backfill
  entry point.
- `Posts.PostVersion` and `Comments.CommentVersion` only gain `@type t` in
  `lib/philomena/posts/post_version.ex:7` and
  `lib/philomena/comments/comment_version.ex:7`; their associations have no
  query-time `where` clauses. The normalized-version migration remains
  structurally identical between refs (`priv/repo/migrations/20260716190444_normalize_versions.exs`);
  its diff only updates comments.

Existing relevant indexes in `priv/repo/structure.sql` are unchanged between
refs: primary keys on `post_versions`, `comment_versions`, and
`versions_legacy`; `(post_id, created_at)` and `(comment_id, created_at)`;
`user_id` on each normalized table; and
`versions_legacy(item_type, item_id)`. The history indexes cover the equality
filter and leading time order. They do not include `id`, so a same-timestamp
tie-break may still require a sort, but that is an unchanged property and not
an index candidate for this comparison. The one-time backfill's item-type and
item-id access is likewise covered at its leading columns; no new index is
justified without representative plan evidence.

## New, deleted, moved, or ambiguous sites

- The old post-history route used three controller-side queries: forum by
  `short_name`, topic by `(forum_id, slug)`, and post by `(topic_id, id)`;
  current `Posts.list_post_history/4` owns the same hierarchy and adds the
  `Forums.Visibility.available_posts/2` scope for non-staff actors. That scope
  adds `destroyed_content = false AND (approved = true OR user_id = ? OR ip = ?)`
  to the post query. This is a changed, index-relevant caller shape, but it is
  owned by the Posts/Forums visibility audit, not Versions; no Versions index
  recommendation is made here. It is also a semantic visibility change that
  should be checked separately from index coverage.
- The old comment-history route used the image loader plus a comment query
  scoped by `(image_id, id)` with `image`, `deleted_by`, and user award/badge
  preloads. Current `Comments.list_comment_history/3` uses the shared Loader
  over the same parent-scoped comment predicate and expands the declared image
  preloads. These are moved caller/preload queries owned by Comments, Images,
  and shared Loader code; the Version history query itself is unchanged.
- No Versions-owned SQL site was deleted or left without a counterpart. Rule
  and static-page version queries/schema changes are owned by the Rules and
  StaticPages contexts in the assignment matrix and were not counted here.

## Follow-ups

- Link the post-history visibility predicate to the canonical Posts/Forums and
  shared Loader findings. Verify whether unavailable posts should be reported
  as not-found or unauthorized before considering any index change.
- If version histories become large, obtain a representative `EXPLAIN` for
  `WHERE post_id = ? ORDER BY created_at DESC, id DESC LIMIT 26` and its comment
  equivalent. A covering `(foreign_key, created_at DESC, id DESC)` index could
  remove the unchanged tie-break sort, but current evidence does not support
  adding it as a delta-driven recommendation and it would add write/storage
  cost.
- Legacy backfill remains a one-time maintenance workload. Any future index
  work for its `DISTINCT ON` or window ordering should be plan- and dataset-
  driven rather than inferred from the unchanged SQL.
