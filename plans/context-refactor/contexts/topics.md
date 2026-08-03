# Topics context plan

Source: `lib/philomena/topics.ex`; consumers: HTML/JSON topic list/show/create,
read/subscription/stick/lock/move/hide/title controllers, Posts/Polls/PollVotes,
notifications, and indexing.

## Findings

- Forum/topic loading has custom triple-shaped success values and bespoke hidden
  visibility. Public `list_public_topics/2` and `load_public_topic/2` are marked
  for deletion in favor of actor-scoped APIs.
- `topic_page_number/2` loads a post by ID without constraining it to the parent
  topic (explicit FIXME) and parses IDs locally.
- New-topic uses `verify_not_banned/1`; create uses
  `verify_write_access/1`. Moderation operations repeat parent load plus action
  authorization and sometimes nest additional `with ... else` logic.
- The `change_topic` comment notes role/notification oddities; create has a
  broadcast FIXME. Raw loaded-record CRUD and query helpers remain public.

## Work

- Make one actor-first forum/topic loader return a typed pair/result, safely load
  forum then topic scoped by `forum.id`, apply hidden visibility, and authorize
  the requested action. Use it across Topics, Posts, Polls, and PollVotes.
- Delete both public bypass APIs and migrate HTML/JSON callers to anonymous Actor
  use. Preserve no separate “public” query semantics.
- Scope the requested post ID to the loaded topic when computing pagination;
  malformed, missing, or another-topic IDs must not influence the page.
- Replace `verify_not_banned/1` with `verify_write_access/1` on new. Use explicit
  subscribe/read/stick/lock/move/hide/update actions and validate target forum
  through the same safe forum loader.
- Resolve `change_topic` behavior by moving role-change side effects and
  notification clearing into named transaction steps. Move create broadcasts and
  notifications into the owning context after commit/transaction policy.
- Make raw create/modifier/query helpers private; retain documented last-post/
  notification services only for real cross-context callers. Reorder private
  load/query/transaction mechanics before public APIs.

## TODO/FIXME resolution

- Fix role-change and notification behavior around changesets.
- Scope page-number post loading to the topic.
- Delete both public actor-bypass APIs.
- Own create broadcasts in the context.

## Verification

- Matrix-test unknown/restricted forums; malformed/missing/wrong-forum/hidden
  topics; wrong-topic post pagination; every moderation action; invalid target
  forum; form/write parity; subscriptions/read state; notification clearing;
  broadcasts; and HTML/JSON parity.
