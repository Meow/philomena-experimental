# Notifications SQL shape audit

Refs: master -> context-logic
Status: complete

--- relevant files ---

plans/sql-query-shape-audit.md
lib/philomena/notifications.ex
lib/philomena/notifications/category.ex (master-only)
lib/philomena/notifications/creator.ex (master-only)
lib/philomena/notifications/channel_live_notification.ex
lib/philomena/notifications/forum_post_notification.ex
lib/philomena/notifications/forum_topic_notification.ex
lib/philomena/notifications/gallery_image_notification.ex
lib/philomena/notifications/image_comment_notification.ex
lib/philomena/notifications/image_merge_notification.ex
lib/philomena/images.ex
lib/philomena/channels.ex
lib/philomena/galleries.ex
lib/philomena/posts.ex
lib/philomena/topics.ex
lib/philomena/comments.ex
lib/philomena/channels/subscription.ex
lib/philomena/forums/subscription.ex
lib/philomena/topics/subscription.ex
lib/philomena/galleries/subscription.ex
lib/philomena/images/subscription.ex
lib/philomena_web/controllers/notification_controller.ex
lib/philomena_web/controllers/notification/category_controller.ex
lib/philomena_web/controllers/notification/unread_controller.ex
lib/philomena_web/plugs/notification_count_plug.ex
lib/philomena_web/views/notification_view.ex
test/philomena/notifications_test.exs
test/philomena_web/controllers/notification_controller_test.exs
test/philomena_web/controllers/notification/category_controller_test.exs
test/philomena_web/controllers/notification/unread_controller_test.exs
priv/repo/structure.sql
priv/repo/migrations/20240728191353_new_notifications.exs
priv/repo/migrations/20240818182358_cleanup.exs

Query sites inspected: 20 notification query families, including six category
branches, six fan-out branches, six clear operations, two image-migration
branches, their preloads, and the moved callers.

no SQL shape changes found in the retained/moved Notifications workloads.

## Changed shapes

### Unknown category fallback branch was removed

- Master: `lib/philomena_web/controllers/notification/category_controller.ex:6-20`
  maps every unknown route id to `:forum_post`, then calls
  `Category.unread_notifications_for_user_and_category/3`. That emitted the
  forum-post notification query: base `forum_post_notifications`, fixed
  `user_id = $1`, `ORDER BY updated_at DESC`, Scrivener `LIMIT/OFFSET`, and the
  `[topic: :forum, post: :user]` preloads.
- context-logic: `lib/philomena/notifications.ex:181-189,264-274` parses the
  route parameter and returns `{:error, :not_found}` for an unknown category;
  no notification query is issued. The controller delegates the error to the
  fallback at `lib/philomena_web/controllers/notification/category_controller.ex:6-20`.
- Delta: deleted an invalid-input workload; the valid forum-post query shape is
  unchanged. This is a correctness/HTTP behavior change, not an index change.
- Index status: no index action
- Evidence: the valid forum-post path remains covered by
  `forum_post_notifications_user_id_updated_at_desc_index` and the existing
  notification preload/FK indexes. No index is justified for a request branch
  that no longer performs SQL.
- Confidence: high

## Unchanged or non-index-relevant sites

- Unread category pages (`Category.unread_notifications_for_user/2` and
  `Category.unread_notifications_for_user_and_category/3` in master;
  `Notifications.list_unread_notifications/2`,
  `show_unread_notification_category/3`, and private `unread_page/3` in
  `lib/philomena/notifications.ex:85-96,240-274`) preserve six per-user
  collection shapes. Each is a notification table with `WHERE user_id = $1`,
  `ORDER BY updated_at DESC`, Scrivener `LIMIT/OFFSET` plus its count query,
  and the same category-specific preloads. There is no `read = false`
  predicate in either ref.
- The category preload queries are unchanged: channel, gallery, topic/forum,
  post/user, image/source/tag/alias, comment/user, and source/target image
  lookups are all association primary-key or foreign-key loads. The six
  notification schemas (`lib/philomena/notifications/*_notification.ex`) have
  no association `where` or `order_by` clauses that alter these queries.
- Total unread count (`Category.total_unread_notification_count/1` at master
  `category.ex:47-57`; `Notifications.total_unread_count/1` at
  `notifications.ex:205-220`) remains a `UNION ALL` of six branches, each
  selecting a constant from its notification table with `user_id = $1`, then
  `Repo.aggregate(:count)`. The changed anonymous-actor fast path issues no
  SQL, equivalent to the controller's old skipped anonymous path.
- Notification fan-out (`Creator.broadcast_notification/1` at master
  `creator.ex:34-48`; private `broadcast_notification/1` at
  `notifications.ex:98-154`) retains six source subscription shapes:
  `channel_id`, `topic_id`, `forum_id`, `gallery_id`, or `image_id` equality,
  with an optional residual `user_id <> $author` predicate. The projected
  insert query still targets the corresponding notification table with
  `user_id`, timestamps, `read = false`, and event foreign keys, followed by
  `insert_all` with conflict target `(event_key, user_id)` and replacement of
  all columns except `created_at`.
- The six clear operations (`notifications.ex:426-526`, formerly
  `notifications.ex:193-277`) retain `DELETE` predicates combining the event
  key (`channel_id`, `topic_id`, `gallery_id`, `image_id`, or `target_id`)
  with `user_id = $1`. The nil-user branch remains a no-op and does not issue
  SQL.
- Image notification migration is moved from
  `master:lib/philomena/images.ex:1505-1536,
migrate_subscriptions/2` to `lib/philomena/notifications.ex:531-568`,
  composed through `Multi.run/3`. The two source selects retain
  `image_comment_notifications WHERE image_id = $source` and
  `image_merge_notifications WHERE target_id = $source`, projecting the
  recipient/event fields for target insertion; the two `on_conflict: :nothing`
  inserts and two deletes retain the same target relations and predicates.
  The surrounding subscription migration remains Images-owned and is not
  reclassified as a Notifications query.
- Moved callers in `Channels`, `Galleries`, `Images`, `Posts`, and `Topics`
  now call the renamed broadcast/clear services. The controller index and
  category pages call actor-scoped wrappers, while
  `NotificationCountPlug` calls `total_unread_count/1`; these API and
  authorization changes do not alter the final SQL for authenticated users.
- `lib/philomena_web/controllers/notification/unread_controller.ex`, the
  notification views/templates, and category parsing/rendering contain no
  additional SQL. OpenSearch and presentation changes were excluded.

## New, deleted, moved, or ambiguous sites

- `lib/philomena/notifications/category.ex` and
  `lib/philomena/notifications/creator.ex` are deleted in context-logic. Their
  query builders were inlined into `Philomena.Notifications`; this is module
  movement, not new SQL.
- The master `Images.migrate_subscriptions/2` notification selects/inserts/
  deletes are split out into `Notifications.put_migrate_image_notifications/3`
  and composed into the image merge `Philomena.Multi`. Stable predicates and
  target tables pair the old and current operations.
- `Category.notification_category/1` is deleted, but it was an in-memory
  struct classifier and issued no SQL. The current route parser is likewise
  non-SQL except for the removed unknown-category fallback described above.
- No unpaired Notifications-owned worker or maintenance query was found.
  No ambiguous query site was found in the moved callers or notification
  schemas.

## Follow-ups

- Correctness, unchanged: all notification reads are named “unread” but neither
  ref filters on `read = false`; the `read` column is only set on fan-out and
  rows are cleared by deletion. If read-state rows are introduced or retained,
  adding a read predicate would be a new query shape requiring a separate
  audit.
- Pagination stability, unchanged: category pages order only by
  `updated_at DESC`, without a unique tie-breaker. If deterministic page
  boundaries are required, add an explicit tie-breaker and reassess the
  `(user_id, updated_at DESC, ...)` index shape.
- Schema coverage: `priv/repo/structure.sql` has, for every notification table,
  the unique `(user_id, event_key)` index, `(user_id, updated_at DESC)`,
  `(user_id, read)`, and standalone event-FK indexes. The subscription tables
  have unique `(event_key, user_id)` indexes plus `user_id` indexes. These
  cover per-user/date ordering, conflict targets, clear/migration predicates,
  and fan-out lookups. The notification-related structure and migration
  portions are unchanged between master and context-logic.
- The relevant history is `20240728191353_new_notifications.exs:15-31`, which
  created the notification tables and indexes, and
  `20240818182358_cleanup.exs:264-278`, which only normalized timestamp types.
  No representative `EXPLAIN` or workload statistics were available; no
  candidate remains after the schema-coverage check, so no index is proposed.
- Shared-query links for coordinator synthesis: subscription lookup/index
  ownership is shared with `Philomena.Subscriptions` and the source-specific
  subscription schemas; image merge composition is consumed by `Images`.
