# Forums SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 29 normalized sites, including moved controller/plugs, nested Forums modules, generated subscription queries, and Forum-owned transaction/visibility helpers

## Changed shapes

### Visible forum index and navigation list

- Master: `lib/philomena_web/controllers/forum_controller.ex` (master, index) and `lib/philomena_web/plugs/forum_list_plug.ex` (master, `lookup_visible_forums/1`): `forums` scan ordered by `name`, with `last_post -> user/topic -> forum` preload; the controller separately aggregates `sum(forums.topic_count)` over all forums and filters the loaded rows in memory with authorization. The plug uses the same ordered scan and in-memory visibility filter.
- context-logic: `lib/philomena/forums.ex:25-68`, callers `lib/philomena_web/controllers/forum_controller.ex:8-15` and `lib/philomena_web/plugs/forum_list_plug.ex:8-11`: `forums` filtered by actor branch (`access_level = 'normal'`, `IN ('normal','assistant')`, or no access predicate), ordered by `name`; the paginated variant runs `sum(topic_count)` over that filtered relation, then applies pagination and preloads only the page.
- Delta: visibility moved into SQL; the index operation gained aggregate/pagination query shapes and page-scoped preloads. The plug now uses an unpaginated actor-filtered query. The old in-memory authorization behavior is not relationally equivalent for staff branches, and the old controller aggregate counted restricted forums while the new aggregate does not.
- Index status: no index action
- Evidence: `priv/repo/structure.sql` has no `forums.access_level` or `forums.name` index. `access_level` is low-cardinality and `name` is used for a small full forum listing; the existing primary key and `index_forums_on_short_name` are not relevant to this ordering. No representative plan was run; the stack is running but no database changes were made.
- Confidence: high

### Forum page lookup and topic collection

- Master: `lib/philomena_web/controllers/forum_controller.ex` (master, show), with framework resource loading by `short_name`, followed by `Topic |> where(forum_id: forum.id) |> where(hidden_from_users: false) |> order_by(desc: sticky, desc: last_replied_to_at) |> preload([:poll, :forum, :user, last_post: :user]) |> Repo.paginate/1`.
- context-logic: `lib/philomena/forums.ex:19-23,121-129`, called by `lib/philomena_web/controllers/forum_controller.ex:18-27` and the JSON forum topic controller: forum `short_name = ?` lookup, then `topics.forum_id = ?` plus `Visibility.visible_topics/2` (no hidden predicate for admin/moderator/assistant; `hidden_from_users = false` otherwise), the same ordering/preloads, and pagination.
- Delta: the forum member lookup is an explicit context query but retains the unique slug predicate. Topic visibility is now actor-dependent, so staff collection queries omit the hidden filter. The paginated count query inherits the same branch. This is a semantic visibility change as well as a SQL-shape change.
- Index status: covered
- Evidence: `index_forums_on_short_name` covers the forum lookup; `index_topics_on_forum_id` covers the parent scope; `index_topics_on_forum_id_and_slug` covers the forum/slug member variant used by moved topic callers. `index_topics_on_last_replied_to_at` exists, but no composite ordering index on `(forum_id, sticky, last_replied_to_at)` exists; the current forum list is small and the existing foreign-key/order indexes provide a plausible path, so no candidate is proposed without workload/plan evidence.
- Confidence: high

### Forum member CRUD and subscription route lookup

- Master: admin resource plugs loaded forums by unique `short_name`; updates operated on the loaded primary-key row. Forum subscription resource plugs did the same, then generated subscription existence/insert/delete queries.
- context-logic: `lib/philomena/forums.ex:19-23,152-175,230-253` explicitly queries `forums.short_name = ?` through `Loader.one_and_authorize/3` before update or subscription work. Generated subscription sites are `lib/philomena/subscriptions.ex:109-157`, instantiated for `Philomena.Forums` with `forum_id`.
- Delta: selection moved from framework loaders/loaded structs into a context query; the update target is now selected by `short_name` before `Repo.update/1`. Subscription existence and delete remain `forum_id = ? AND user_id = ?`; insert remains an upsert-on-conflict against the same composite key.
- Index status: covered
- Evidence: `index_forums_on_short_name` covers route selection; `forum_subscriptions` has unique `(forum_id, user_id)` and an additional `user_id` index, covering existence/delete and the conflict target. The subscription helper is shared; broader cross-context review is a linked follow-up rather than a Forums recommendation.
- Confidence: high

### Route-scoped locking workflows

- Master: moved callers in `lib/philomena/posts.ex` and `lib/philomena/topics.ex` loaded forum/topic/post records separately, generally by already-loaded IDs; topic creation used a topic lock by `forum_id`, and post operations used a post/topic preload. The old forum last-post/counter updates targeted `forums.id = ?`.
- context-logic: `lib/philomena/forums/transaction_workflow.ex:82-155` locks `forums.short_name = ?`, then locks `topics.slug = ?` constrained by `EXISTS (forums.short_name = ? AND topic.forum_id = forum.id)`; `:186-249` adds sorted source/target `forums.short_name = ?` locks and the source-scoped topic lock; `:279-328` adds `posts.id = ?` constrained by nested topic/forum `EXISTS` predicates; `:375-380` finds `max(posts.topic_position)` for `posts.topic_id = ? ORDER BY topic_position DESC LIMIT 1`.
- Delta: workflow queries are newly centralized and route-scoped. Forum selection changed from loaded primary-key records to unique slug predicates; topic selection changed from ID/parent-ID lookup to slug plus parent forum existence; post selection adds route-parent existence checks. Row locks are now explicit and are acquired in a deterministic forum/topic/post order. These are index-relevant lookup/predicate changes and locking queries, not merely module movement.
- Index status: covered
- Evidence: forum slug lookups use `index_forums_on_short_name`; topic route lookup uses `index_topics_on_slug` plus the forum primary/short-name lookup (and the composite `(forum_id, slug)` index remains available for the equivalent direct parent-scoped form); post ID uses `posts_pkey`; post position uses the unique `(topic_id, topic_position)` index, which supports the descending top-row lookup. No new index is justified from source/schema evidence.
- Confidence: high

### Forum last-post refresh and denormalized counter updates

- Master: `lib/philomena/forums.ex` exposed `update_forum_last_post_query/1`, an `UPDATE forums SET last_post_id = (SELECT max(posts.id) FROM posts JOIN topics ON posts.topic_id = topics.id WHERE topics.forum_id = ? AND topics.hidden_from_users IS FALSE AND posts.hidden_from_users IS FALSE) WHERE forums.id = ?`; old topic/post callers composed this with `Ecto.Multi.update_all`. Counter updates were previously composed in the topic/post contexts.
- context-logic: `lib/philomena/forums.ex:276-415` retains the same last-post fragment and `forums.id = ?` update predicate, and adds `update_all` counter updates by `forums.id = ?` for topic transfer, topic visibility, and post visibility. The workflow invokes these via `Philomena.Multi` in moved callers such as `lib/philomena/topics.ex:613-615` and `lib/philomena/posts.ex:302-305,489-490,555-556,627-628`.
- Delta: last-post SQL shape is unchanged apart from the operation being deferred through the locking workflow. Counter updates are new Forums-owned update shapes, but all target the primary key and use no changed row-selection predicate. The fragment remains a correctness-sensitive visibility query; it is not a new generic index recommendation.
- Index status: covered
- Evidence: `forums.id` is the primary key; the fragment joins through `posts.topic_id` and filters `topics.forum_id`, covered by `index_posts_on_topic_id_and_created_at`/the topic foreign-key index and `index_topics_on_forum_id`. The max-by-ID subquery has no dedicated `(forum_id, hidden_from_users, id)` path, but workload/cardinality evidence and a plan are absent, so no candidate is proposed.
- Confidence: high

### Visibility query scopes

- Master: controller/topic/post callers expressed fixed `hidden_from_users = false` and availability predicates inline or filtered after loading; there was no Forums-owned reusable visibility query module.
- context-logic: `lib/philomena/forums/visibility.ex:25-145` adds actor branches for forum `access_level`, topic hidden state, and post hidden/approved/destroyed/account/IP predicates. `visible_topics/2` is used by the Forums forum page; `visible_forums/2` and `available_posts/2` are also used by moved topic/post callers.
- Delta: new query builders replace scattered caller predicates and deliberately produce different relational shapes for staff versus non-staff actors. `visible_forums/2` and `visible_topics/2` affect the Forums-owned page/index operations; post scopes are shared follow-up material and are linked here only.
- Index status: needs plan evidence
- Evidence: the forum access predicate is low-cardinality and has no existing index; the post `OR` account/IP/approval predicate and hidden/destroyed flags are not suitable for a generic B-tree recommendation. No EXPLAIN evidence was collected, so no index candidate is promoted.
- Confidence: medium

## Unchanged or non-index-relevant sites

- `lib/philomena/forums.ex:403-414` last-post refresh retains the master `forums.id` update target and the same `max(posts.id)` join/filter fragment; only the transaction composition changed.
- `lib/philomena/forums.ex:152-175` subscription create/delete callers are moved wrappers; generated `subscribed?/2`, `subscriptions/2`, `create_subscription/2`, and `delete_subscription/2` SQL retains the same equality predicates and composite-key conflict behavior as master. Shared helper follow-up: `lib/philomena/subscriptions.ex`.
- `lib/philomena/forums/transaction_workflow.ex:375-380` max topic position is materially the same `topic_id` equality plus descending `topic_position` top-row query as the old post-creation workflow; it is moved into a Forums-owned workflow and is covered by `index_posts_on_topic_id_and_topic_position`.
- `lib/philomena/forums/forum.ex:8-17` has no association `where` clause; its `last_post`, `last_topic`, and `subscriptions` associations only cause ordinary primary/foreign-key preload queries. `lib/philomena/forums/subscription.ex:10-13` has no association filter.
- Forum inserts and changeset validation do not change row-selection SQL. `update_forum/3` changes the preceding lookup shape, covered above; the final `UPDATE forums WHERE id = ?` remains primary-key targeted.
- OpenSearch serialization in `Visibility.search_filters/1` was excluded from this PostgreSQL audit.

## New, deleted, moved, or ambiguous sites

- `lib/philomena/forums/forum_index.ex`, `forum_page.ex`, `visibility.ex`, and `transaction_workflow.ex` are new context-owned modules. Their SQL-bearing sites are paired above with the old controller/topic/post callers where a counterpart exists; genuinely new counter-update branches are recorded above as new workloads.
- `get_forum!/1`, `delete_forum/1`, and `change_forum/1` were removed from the public Forums API. Their old operations were primary-key/member-loaded operations with no remaining caller in the inspected `context-logic` call sites; no replacement SQL workload was found.
- `lib/philomena_web` resource-loader queries are framework-generated on master, so their exact SQL text was not independently generated. The source-level predicate is unambiguous (`short_name` for forums), and the unique index evidence is sufficient for classification.
- No database container/EXPLAIN inspection was used. `docker compose ps` confirmed the application/Postgres services are running, but this audit intentionally performed no SQL writes or database setup; plan evidence remains a follow-up if table growth or production workload warrants it.

## Follow-ups

- Reconcile the canonical forum/topic/post lock and visibility shapes with the
  Topics, Posts, and Comments reports in `shared.md`; review the broader staff
  visibility and forum aggregate behavior as correctness questions.
- Validate forum/topic pagination and last-post refresh plans with representative
  production-like data before considering any composite or partial index.
