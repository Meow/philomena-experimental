# Activities SQL shape audit

Refs: master -> context-logic
Status: complete

--- files ---
plans/sql-query-shape-audit.md
lib/philomena/activities.ex
lib/philomena/activities/front_page.ex
lib/philomena/images.ex
lib/philomena/images/search.ex
lib/philomena/comments.ex
lib/philomena/channels.ex
lib/philomena/channels/query_builder.ex
lib/philomena/topics.ex
lib/philomena/forums/visibility.ex
lib/philomena/interactions.ex
lib/philomena/subscriptions.ex
lib/philomena/images/image.ex
lib/philomena/topics/topic.ex
lib/philomena/channels/channel.ex
lib/philomena_web/controllers/activity_controller.ex
lib/philomena_web/image_loader.ex
lib/philomena_web/comment_loader.ex
test/philomena/activities_test.exs
test/philomena_web/controllers/activity_controller_test.exs
priv/repo/structure.sql
priv/repo/migrations/20260716190444_normalize_versions.exs
priv/repo/migrations/20260806180557_unique_commission_per_user.exs
priv/repo/migrations/20260810212302_cascade_image_intensities_on_image_delete.exs

Query sites inspected: 15

## Changed shapes

### Featured image lookup (`show_featured_image/2`)

- Master: `lib/philomena_web/controllers/activity_controller.ex:60-68`,
  `index/2`; base table `images`, inner join `image_features` on
  `image_features.image_id = images.id`; fixed filter
  `images.hidden_from_users = false`; for an authenticated user unless
  `hidden=1`, a correlated `NOT EXISTS` on `image_hides(image_id, user_id)`;
  `ORDER BY image_features.created_at DESC`, `LIMIT 1`; preloads `sources` and
  `tags` with `aliases`.
- context-logic: `lib/philomena/activities.ex:88-94` calls
  `Philomena.Images.show_featured_image/2`; the query is
  `lib/philomena/images.ex:728-737`. The anonymous, include-hidden, and
  authenticated-exclude-personal-hide branches retain the same predicates,
  join, ordering, and limit. The current query additionally preloads `user`
  and `intensity`.
- Delta: query ownership and authorization moved to the context; the main
  relational shape is unchanged. Two additional association preload queries
  are issued for `users` and `image_intensities`.
- Index status: covered
- Evidence: `image_features(created_at)` and `image_features(image_id)`,
  `image_hides(image_id, user_id)` unique, `images(user_id)`, and the unique
  `image_intensities(image_id)` index exist in both refs' structure dumps.
  Source/tag preload paths are covered by the existing image-source and
  image-tagging primary/unique indexes, plus `tags(id)` and
  `tags(aliased_tag_id)`. No relevant migration changes these paths. The
  existing separate feature indexes could be evaluated with a plan, but the
  lookup shape itself did not change and no new candidate is justified here.
- Confidence: high

### Channel strip (`list_channels/4`)

- Master: `lib/philomena_web/controllers/activity_controller.ex:70-76`,
  `index/2`; base table `channels`, fixed filter
  `last_fetched_at IS NOT NULL`, optional `nsfw = false` when the cookie is
  not `"true"`; `ORDER BY is_live DESC, title ASC`, `LIMIT 6`; no count,
  subscription lookup, or association preload.
- context-logic: `lib/philomena/activities.ex:97-103` calls
  `Philomena.Channels.list_channels/4`, whose chain is at
  `lib/philomena/channels.ex:98-108`. `QueryBuilder.build_query(%{})` is a
  no-op, and the stream data query retains the same filters, ordering, and
  six-row page. `Repo.paginate` adds page-1 pagination and a separate count
  query with the same filters. The operation now preloads
  `associated_artist_tag`; signed-in actors also run the generic channel
  subscription query from `lib/philomena/subscriptions.ex:125-137`.
- Delta: the bounded `Repo.all(... |> limit(6))` became a paginated data query
  plus `COUNT(*)`; the added preload and authenticated subscription lookup are
  new SQL sites. The `nsfw` branch is otherwise equivalent.
- Index status: needs plan evidence
- Evidence: `channels(last_fetched_at)`, `channels(is_live)`, and
  `channels(associated_artist_tag_id)` exist in both refs. The subscription
  lookup on `(channel_id IN (...), user_id = ?)` is covered by the unique
  `channel_subscriptions(channel_id, user_id)` index (and the user-id index).
  The tag preload uses the tag primary key. There is no changed equality/range
  ordering combination that supports a defensible new index without an
  `EXPLAIN` and workload/cardinality data; no candidate is proposed.
- Confidence: high

### Front-page topic strip (`list_front_page_topics/2`)

- Master: `lib/philomena_web/controllers/activity_controller.ex:78-87`,
  `index/2`; base table `topics` inner-joined to `forums` on
  `forums.id = topics.forum_id`; fixed filters
  `topics.hidden_from_users = false`, title regex `!~ 'NSFW'`, and
  `forums.access_level = 'normal'`; `ORDER BY last_replied_to_at DESC`,
  `LIMIT 6`; preloads `forum` and `last_post.user`.
- context-logic: `lib/philomena/activities.ex:97-101` calls
  `lib/philomena/topics.ex:123-132`. The current query joins a subquery from
  `Forums.Visibility.visible_forums/2`, applies
  `Visibility.visible_topics/2`, retains the title regex and ordering, and
  uses `Repo.paginate` with page size 6. This adds a count query and changes
  the visibility branches:
  - anonymous viewers still get normal forums and non-hidden topics;
  - assistants get `access_level IN ('normal', 'assistant')`;
  - moderators/administrators have no forum-access or hidden-topic predicate.
    Preload associations are unchanged and have no association `where` or
    ordering clauses in `Topic`/`Forum`.
- Delta: changed join representation (direct forum join to visible-forum
  subquery), actor-dependent forum/topic predicates, and pagination count
  query. The assistant/staff visibility expansion is a semantic correctness
  change, not an index recommendation.
- Index status: needs plan evidence
- Evidence: `topics(forum_id)`, `topics(hidden_from_users)`,
  `topics(last_replied_to_at)`, and `forums(id)` primary-key coverage exist in
  both refs. Topic/forum/last-post/user preloads use foreign-key or primary-key
  lookups. There is no `forums(access_level)` or composite topic index added by
  the branch. A composite or partial index for the visible, ordered page would
  need representative plans and workload selectivity; no candidate is
  proposed from source/schema evidence alone.
- Confidence: high

### Interaction fan-out (`user_interactions/2`)

- Master: `lib/philomena_web/controllers/activity_controller.ex:89-93` calls
  `Philomena.Interactions.user_interactions/2` with four image collections and
  the current user. `lib/philomena/interactions.ex` builds four `UNION ALL`
  branches: `image_hides`, `image_faves`, and up/down `image_votes`, each
  filtered by `image_id IN (...)` and `user_id = ?`; vote branches also filter
  `up = true/false`.
- context-logic: `lib/philomena/activities.ex:105-111` passes an `Actor` and
  the same four collections to `Interactions.user_interactions/2`; the query
  branches are `lib/philomena/interactions.ex:41-89`. For non-empty image IDs,
  predicates, union structure, and selected columns are unchanged. The
  current `interactions_for_user([], _user)` clause skips the database query
  entirely when all homepage sections are empty.
- Delta: actor-aware API and empty-input short-circuit; no changed access path
  for the non-empty workload. Anonymous actors still issue no query in either
  ref.
- Index status: covered
- Evidence: unique `(image_id, user_id)` indexes cover all four branches in
  both refs; separate user-id indexes remain available for the same tables.
  The `up` predicate is fully constrained after the unique pair lookup. No
  index action is warranted.
- Confidence: high

## Unchanged or non-index-relevant sites

- Homepage image sections (`images`, `top_scoring`, and authenticated
  `watched`) retain the master `ImageLoader` definitions after moving to
  `Philomena.Images.Search` (`lib/philomena/images/search.ex:70-138`). The
  OpenSearch request bodies are outside this audit. Their Postgres hydration
  still uses `WHERE images.id IN (...)` followed by the same
  `sources`/`tags`/`aliases` preloads through
  `PhilomenaQuery.Search.load_records_from_results/1:836-853`; image primary
  keys and the existing association indexes cover the path.
- The homepage comment definition moved from
  `PhilomenaWeb.CommentLoader.query/3` to
  `Philomena.Comments.comment_search_definition/4` and retains the same
  `created_at DESC` search sort, page 1/page size 6, and comment record
  hydration. Its OpenSearch visibility body is excluded; the SQL record load
  remains `comments.id IN (...)` with `user` and nested image/source/tag
  preloads, all covered by primary/foreign-key indexes.
- `Activities.multi_search/4` (`lib/philomena/activities.ex:28-44`) uses the
  same image and comment preload definitions as the deleted controller helper.
  The named multi-search API changes Elixir result mapping only; it does not
  change the final SQL hydration predicates.
- `Philomena.Activities.FrontPage` contains no query definitions. `TagList`'s
  remaining tag-ID lookup is not called by the homepage operation, and its
  removed write-side helper does not affect homepage SQL.
- The relevant `Image`, `Topic`, `Forum`, `Channel`, and interaction schema
  associations are unchanged for query-affecting `where`/ordering options.

## New, deleted, moved, or ambiguous sites

- The four master controller-local Postgres workloads were moved into the
  `Images`, `Channels`, `Topics`, and `Interactions` contexts and are now
  composed by `Philomena.Activities.list_activities/4`. The old
  `filter_hidden/3` and channel helper disappeared; their SQL behavior is in
  `Images.maybe_exclude_viewer_hides/3` and `Channels.list_channels/4`.
- `PhilomenaWeb.ImageLoader` and `PhilomenaWeb.CommentLoader` were deleted in
  context-logic. Their homepage search definitions have reliable counterparts
  in `Images.Search` and `Comments`; the remaining Postgres hydration sites
  are classified above. No standalone active query was deleted without a
  counterpart.
- `Channels.list_channels/4`, `Topics.list_front_page_topics/2`, the forum
  visibility scopes, subscriptions helper, and interaction loader are shared
  context/helper workloads. The coordinator should canonicalize their
  findings in `shared.md` and link the other context reports to this operation.
- No Activities-owned worker, maintenance, `Repo.update_all`, `delete_all`,
  locking query, or schema association `where` clause was found. No ambiguous
  Activities SQL site remains.

## Follow-ups

- Correctness, separate from indexes: the current topic query intentionally
  exposes assistant-access forums and staff-visible hidden topics, unlike the
  old route's hard-coded public predicates. Confirm this is the desired
  homepage policy and keep the role-branch tests aligned.
- Pagination adds count queries for six-row channels and topic strips even
  though the homepage renders only entries. Consider whether the shared
  listing APIs should expose a no-count bounded mode; this is a workload/API
  decision, not evidence for an index.
- Existing homepage orderings lack stable final tie-breakers: featured images
  use only feature timestamp, channels use live/title, and topics use only
  last-reply timestamp. This is unchanged pagination determinism behavior and
  should be handled separately from index selection.
- `master` and `context-logic` relevant structure indexes are identical. The
  only branch migrations are unrelated commission uniqueness, image-intensity
  delete cascading, and version indexes; no `EXPLAIN` was run because no
  changed query produced a schema-supported, high-confidence index candidate.
