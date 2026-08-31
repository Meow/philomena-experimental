# Conversations SQL shape audit

Refs: master -> context-logic
Status: complete

--- repo status ---

The worktree was clean for this report before the report file was created. No
application code, migration, or structure dump was changed.

--- candidate files ---

lib/philomena/conversations.ex
lib/philomena/conversations/conversation.ex
lib/philomena/conversations/message.ex
lib/philomena/conversations/query_builder.ex
lib/philomena/conversations/query_form.ex
lib/philomena/conversations/conversation_index.ex
lib/philomena/conversations/conversation_page.ex
lib/philomena_web/controllers/conversation_controller.ex
lib/philomena_web/controllers/conversation/message_controller.ex
lib/philomena_web/controllers/conversation/message/approve_controller.ex
lib/philomena_web/controllers/conversation/read_controller.ex
lib/philomena_web/controllers/conversation/hide_controller.ex
lib/philomena_web/controllers/conversation/report_controller.ex
lib/philomena_web/plugs/notification_count_plug.ex
lib/philomena/reports.ex
lib/philomena/reports/report.ex
lib/philomena_web/views/conversation_view.ex
lib/philomena_web/views/conversation/message_view.ex
lib/philomena_web/views/message_view.ex
test/support/fixtures/conversations_fixtures.ex
test/philomena/conversations_test.exs
test/philomena_web/controllers/conversation_controller_test.exs
test/philomena_web/controllers/conversation/read_controller_test.exs
test/philomena_web/controllers/conversation/message_controller_test.exs
test/philomena_web/controllers/conversation/hide_controller_test.exs
test/philomena_web/controllers/conversation/report_controller_test.exs
test/philomena_web/controllers/conversation/message/approve_controller_test.exs
lib/philomena_web/templates/conversation/index.html.slime
lib/philomena_web/templates/conversation/new.html.slime
lib/philomena_web/templates/conversation/show.html.slime
lib/philomena_web/templates/conversation/message/_form.html.slime
lib/philomena_web/templates/message/_message.html.slime

Query sites inspected: 11 owned or directly composed sites, including both
branches of the conversation index, both message-order branches, member and
parent-scoped loaders, the unread aggregate, message-count aggregate, and
approval update. The report preload and notification call sites were also
traced; shared query shapes are identified below.

--- index and schema evidence ---

`priv/repo/structure.sql` is materially unchanged for these tables between the
refs. `conversations` has primary key `id` and ordinary B-tree indexes on
`from_id`, `to_id`, and `(created_at, from_hidden)`; it has no index on `slug`,
`last_message_at`, or the read/hidden flag combinations. `messages` has primary
key `id`, B-tree `(conversation_id, created_at)`, and B-tree `from_id`.
There is no conversation/message-specific index migration in the compared
history. The reportable-association migration adds the shared partial index
`reports_conversation_id_index` on `reports(conversation_id) WHERE
conversation_id IS NOT NULL`; that index belongs to the Reports/shared finding,
not to a Conversations-owned shape.

## Changed shapes

### Paginated conversation index, default branch

- Master: `Philomena.Conversations.list_conversations/3` at
  `lib/philomena/conversations.ex:68-87`, called by
  `PhilomenaWeb.ConversationController.index/2`. Base `conversations`, select
  all conversation columns plus the virtual lateral count; fixed participant
  visibility is `(from_id = user_id AND NOT from_hidden) OR (to_id = user_id
AND NOT to_hidden)`. An `INNER LATERAL` subquery counts `messages` by
  `conversation_id = parent.id`; preloads `to` and `from`; order is
  `last_message_at DESC`; pagination applies its limit/offset and count query.
- context-logic: `Philomena.Conversations.QueryBuilder.search_conversations/2`
  through `conversation_index_query/1`, `assign_message_count/1`,
  `apply_sort/1`, and `apply_preloads/1` at
  `lib/philomena/conversations/query_builder.ex:22-81`, called by
  `Philomena.Conversations.list_conversations/3` at
  `lib/philomena/conversations.ex:86-100`. Same base, predicates, lateral
  count, selected columns, preloads, and pagination; order is
  `last_message_at DESC, id DESC`.
- Delta: added `id DESC` as a deterministic pagination tie-breaker. This is
  `changed, index-relevant` because the ordering shape changed, although the
  leading ordering expression and access requirements are unchanged.
- Index status: needs plan evidence; no automatic candidate.
- Evidence: the current `(conversation_id, created_at)` message index covers
  the lateral count's equality lookup only indirectly through its leading
  column. No current conversation index covers `last_message_at` ordering.
  The participant `OR` and hidden predicates make a generic single B-tree
  recommendation uncertain. A possible workload-specific pair would put
  `(from_id, last_message_at DESC, id DESC)` and
  `(to_id, last_message_at DESC, id DESC)` first, but this needs representative
  `EXPLAIN` and selectivity/size evidence before being proposed.
- Confidence: high.

### Paginated conversation index, `with` partner branch

- Master: `Philomena.Conversations.list_conversations_with/3` at
  `lib/philomena/conversations.ex:49-57`, then `list_conversations/3` at
  `:68-87`. Base predicate is the partner/user OR pair
  `(from_id = partner_id AND to_id = user_id) OR (to_id = partner_id AND
from_id = user_id)`, conjoined with the participant hidden predicate from
  `list_conversations/3`; it has the same lateral message count, preloads, and
  `last_message_at DESC` order.
- context-logic: `QueryBuilder.maybe_filter_partner/3` at
  `lib/philomena/conversations/query_builder.ex:48-59`, composed with the same
  builder chain. Same partner and participant predicates, lateral count,
  preloads, and pagination; order is `last_message_at DESC, id DESC`.
- Delta: only the `id DESC` tie-breaker; predicate grouping is semantically the
  same conjunction despite being built in a different order. `changed,
index-relevant`, for the same pagination-order reason as the default branch.
- Index status: needs plan evidence; no automatic candidate.
- Evidence: primary/foreign-key coverage is present for the two participant
  equality columns only as separate indexes (`from_id`, `to_id`). The partner
  branch has two equality pairings and no composite pair indexes. The OR and
  small-result nature of a specific-partner lookup make a new index uncertain.
- Confidence: high.

### Paginated messages in a conversation

- Master: `Philomena.Conversations.list_messages/4` at
  `lib/philomena/conversations.ex:226-240`, called from the controller show
  action. Base `messages`, all message columns, fixed
  `conversation_id = conversation.id`, preload `from`, and order
  `created_at ASC` or `DESC` according to `messages_newest_first`; pagination
  applies limit/offset and its count query.
- context-logic: `Philomena.Conversations.show_conversation/3` at
  `lib/philomena/conversations.ex:146-160`. Same base, filter, preload, and
  direction branch, with order `created_at ASC, id ASC` or
  `created_at DESC, id DESC`.
- Delta: added `id` tie-breaker in both direction branches. `changed,
index-relevant` as an ordering/pagination change.
- Index status: needs plan evidence; no automatic candidate.
- Evidence: existing `index_messages_on_conversation_id_and_created_at` covers
  the equality plus leading timestamp ordering. It does not include `id` for a
  fully index-ordered tie-break, so `(conversation_id, created_at, id)` could
  reduce incremental sorting, but there is no representative plan, table-size,
  or workload evidence to justify its write/storage cost.
- Confidence: high.

### Parent-scoped approval message lookup

- Master: the approve controller's Canary resource loader at
  `lib/philomena_web/controllers/conversation/message/approve_controller.ex:9-13`
  loads `Message` by primary-key `id` and preloads `conversation`; the context
  then runs `Philomena.Conversations.approve_message/2` at
  `lib/philomena/conversations.ex:293-308`, including
  `UPDATE conversations SET ... WHERE id = message.conversation_id`.
- context-logic: `load_conversation/4` at
  `lib/philomena/conversations.ex:34-39` first loads by `conversations.slug`;
  `load_conversation_message/4` at `:41-50` builds `messages WHERE
conversation_id = conversation.id` and `Loader.fetch_and_authorize/5` adds
  `id = message_id`, with the same conversation preload. Approval then runs
  `create_message_approve/3` at `:372-395`, with the same conversation
  update-by-primary-key predicate.
- Delta: new route-parent slug lookup and an added parent predicate to the
  message primary-key lookup. `changed, index-relevant` for the added lookup
  predicates, but the message primary key covers `id` and the conversation
  primary key covers the update. This is also a correctness improvement: a
  message from another conversation is rejected rather than approved through
  this nested route.
- Index status: covered for message and conversation ID lookups; no index action
  for the parent predicate. The slug lookup is a moved/centralized form of the
  old controller's `id_field: "slug"` Canary query, not a new workload; neither
  ref has a slug index. A slug index may be worthwhile independently, but this
  audit has no plan or cardinality evidence to recommend it as a refactor delta.
- Evidence: `conversations_pkey`, `messages_pkey`, and
  `index_messages_on_conversation_id_and_created_at` are present in both
  structure dumps. `Loader.fetch_and_authorize/5` calls `Repo.get` after
  applying the parent query, so the final lookup is `id = ? AND
conversation_id = ?`.
- Confidence: high.

## Unchanged or non-index-relevant sites

- `Philomena.Conversations.unread_conversation_count/1` at
  `lib/philomena/conversations.ex:114-127` is the moved
  `count_unread_conversations/1` shape from master (`:28-37`): aggregate count
  on `conversations` with the same boolean grouping for unread participant
  flag and non-hidden participant side. `changed, likely not index-relevant`
  only in API/authorization placement; SQL predicate shape is unchanged. The
  notification header call at `lib/philomena_web/plugs/notification_count_plug.ex:38-40`
  is an unchanged consumer.
- `Philomena.Conversations.load_conversation/4` at `:34-39` is the semantic
  relocation of the master controller's slug-based Canary loader used by show,
  reply, read, hide, and report routes. It is a member lookup by `slug`, with
  optional `to`/`from` preloads. The preload queries are user primary-key
  lookups and are unchanged/index-covered.
- `show_conversation/3`'s read update at `:148-151` is the moved
  `mark_conversation_read/3` write. It updates the loaded conversation row by
  primary key through `Repo.update`; only the changeset/API shape changed, not
  the row-selection predicate. `update_conversation_read/3` and
  `update_conversation_hide/3` at `:269-292` use the same loaded-row primary
  key update and are unchanged/non-index-relevant.
- `create_conversation/2` at `:226-258` retains the conversation/message insert
  changeset row shapes. Recipient resolution is delegated to the Users context
  (`Users.load_active_user_by_name/2`), so its user-name lookup is outside this
  report. Association insertion does not alter a row-selection predicate.
- `create_message/3` at `:316-352` retains message insert and conversation
  update-by-primary-key shapes. Its `message_count_query` at `:319-322` is the
  moved master `count_messages/1` aggregate at `:202-206`: `messages WHERE
conversation_id = ?`, count result. The explicit `count(message.id)` versus
  aggregate-generated count expression is `changed, likely not
index-relevant`; the existing messages composite index covers the filter.
  The count now runs as `Multi.one` in the transaction after the insert rather
  than as a follow-up call after commit, which changes timing but not the SQL
  shape.
- `create_message_approve/3`'s conversation `UPDATE ... WHERE id = ?` at
  `:375-378` is unchanged and primary-key covered. `Message.approve_changeset`
  changes values only. The report-closing operation composed by
  `Reports.put_close_reports/4` at `lib/philomena/reports.ex:594-600` has the
  shared shape `UPDATE reports SET ... WHERE conversation_id = ? AND open =
true`; ownership and canonical index finding belong in `shared.md`/Reports.
- `Conversation` and `Message` schema associations at
  `lib/philomena/conversations/conversation.ex:13-20` and
  `lib/philomena/conversations/message.ex:11-16` have no association `where`
  clauses. Their `belongs_to`/`has_many` preloads therefore add only standard
  primary-key/foreign-key predicates. No conversation-owned worker or
  maintenance query was found.

## New, deleted, moved, or ambiguous sites

- `QueryBuilder.search_conversations/2`, `QueryForm`, `ConversationIndex`, and
  `ConversationPage` are new modules that split the former context/controller
  implementation. The index and message queries have reliable counterparts
  above; module movement is not itself a shape change.
- `show_conversation/3`, `load_report_target/2`, and the nested approval loader
  make the conversation slug lookup context-owned. This corresponds to the
  old `load_and_authorize_resource` calls, including report and show preloads;
  the slug index absence is pre-existing rather than introduced by
  context-logic.
- The old `list_messages/4`, `count_messages/1`, `mark_conversation_read/3`,
  `mark_conversation_hidden/3`, `approve_message/2`, and controller Canary
  loads are deleted as public functions but are moved/split into the current
  context operations, not deleted workloads.
- Approval now requires both the route conversation and nested message to
  match. This is a semantic/correctness change, not an index recommendation.
  The Reports close query and report target preloads are shared-context
  consumers and should be reconciled with the canonical Reports/shared report.

## Follow-ups

- Run representative `EXPLAIN (FORMAT JSON)` for default and `with` conversation
  pages, and for ascending/descending message pages, before deciding whether
  the new tie-breakers merit `(conversation_id, created_at, id)` or participant
  plus `last_message_at` indexes. The local audit did not have representative
  runtime-plan evidence.
- Confirm the shared report assigns the partial `reports(conversation_id)
WHERE conversation_id IS NOT NULL` index to the report-closing update shape;
  do not duplicate that recommendation here.
- Verify nested approval tests retain the intended parent-scope behavior for a
  valid message ID belonging to a different conversation. No application code
  was changed as part of this audit.
