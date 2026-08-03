# Posts context plan

Source: `lib/philomena/posts.ex`; consumers: HTML/JSON topic-post CRUD/search,
history/report/moderation controllers, indexing, notifications, and user erasure.

## Findings

- Four FIXME-marked public bypass APIs (`list_public_topic_posts`,
  `load_public_topic_post`, `load_public_post`, `search_public_posts`) should be
  replaced by actor-scoped versions. One also uses a one-off pagination shape.
- Nested loading is partly through Topics and partly local. Docs admit that
  several user-controlled post IDs can raise `Ecto.Query.CastError`; report
  loaders appear duplicated.
- Loaded-record create/update/hide/destroy and query/index APIs are public above
  controller orchestration. New/edit/report forms use `verify_not_banned/1`,
  while writes use `verify_write_access/1`.
- Hide/unhide/destroy/approve repeat load/authorization branches, and create has
  a FIXME asking why broadcast behavior was not moved into the context.

## Work

- Delete all four public bypass APIs. Migrate HTML/JSON callers to actor-scoped
  list/show/search loaders, using an anonymous Actor where appropriate and the
  shared generic pagination params.
- Build one parent-scoped post loader: safely parse ID, query by loaded topic ID,
  apply hidden-topic/post visibility, then authorize the requested action.
  Wrong-forum/topic/post combinations and malformed IDs are not-found and never
  cast errors.
- Apply `verify_write_access/1` to new/edit/report form loaders and all writes.
  Consolidate report display/creation loading so the latter only adds the write
  prerequisite and report-specific authorization.
- Extract private create/update/moderation transaction builders; make raw
  loaded-record CRUD and query helpers private. Keep worker/index APIs as a
  separately documented service surface.
- Move post broadcasts/notifications/subscription updates into the owning public
  transaction/after-commit flow. Replace the special pagination branch.
- Reorder private query/load/transaction/index functions before public APIs and
  document approval/hidden visibility, error precedence, and side effects.

## TODO/FIXME resolution

- Remove all public actor-bypass functions.
- Use `Repo.pagination_params()` everywhere.
- Eliminate every documented cast crash.
- Merge duplicate report loaders.
- Own post broadcast behavior in this context.

## Verification

- Matrix-test malformed/missing/wrong-parent/hidden/forbidden posts across every
  show/edit/report/moderation action and actor level. Cover API/HTML parity,
  pagination, form/write prerequisites, transaction/log/broadcast/notification
  behavior, erasure, and OpenSearch updates.
