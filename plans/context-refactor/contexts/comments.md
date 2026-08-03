# Comments context plan

Source: `lib/philomena/comments.ex`; consumers: image comment CRUD/history/report
controllers, JSON search/show APIs, indexing, and user erasure.

## Findings

- The module has two API strata: early loaded-record CRUD/query/index helpers and
  later actor-scoped controller functions. Many early functions are public only
  for internal or erasure/indexing callers.
- Loading varies among raising `load_comment/1`, `Images.load_visible_image/2`,
  scoped `Repo.get_by`, and custom hidden-comment authorization. TODOs explicitly
  call out non-integer crashes and inconsistent fingerprint requirements between
  edit/report form loaders and their writes.
- `comment_filters/3` uses a direct staff-role check; its TODO asks for
  authorization. Hide/unhide/destroy/approve repeat nearly identical load and
  authorization branches.
- `hide_loaded_comment/3` is public for `Users.Eraser`, leaving ownership of the
  erasure service API unresolved.

## Work

- Establish one parent-scoped loader: safely parse comment ID, query by both
  `image_id` and comment ID with required preloads, then apply comment visibility
  or requested action. Use it for show, edit, report, update, moderation, and
  history; mismatched image/comment pairs are not-found.
- Replace `load_comment/1` with a non-raising private/service loader or delete it.
  JSON and controller paths must use the same normalized result contract.
- Apply `verify_write_access/1` to both edit/report form loaders and their write
  counterparts, resolving both fingerprint TODOs in favor of the stricter rule.
- Replace `staff?/1` filtering with authorization-backed query options. Ensure
  hidden-image and hidden-comment rules are checked independently and in a
  documented order.
- Extract one private moderation transaction used by hide/unhide/destroy/approve,
  parameterized by action and modifier. Preserve log, notification, counter,
  broadcast, and reindex effects atomically where feasible.
- Give erasure a narrow explicit function (for example,
  `erase_user_comment/2`) or move orchestration into Comments; make
  `hide_loaded_comment/3`, raw CRUD, query builders, and reindex helpers private
  unless workers require a documented service API.
- Move all private persistence/query/index helpers before the public controller
  and service APIs. Update docs with hidden-resource precedence and side effects.

## TODO resolution

- Do not raise from user-controlled comment IDs.
- Remove direct role checks.
- Require the same fingerprint/write access on form and mutation routes.
- Replace the ambiguous Eraser exposure with a named erasure boundary.

## Verification

- Add a table covering malformed, absent, wrong-image, hidden-image, hidden
  comment, and forbidden comment for anonymous/user/moderator actors.
- Cover form/write parity, moderation side effects, report paths, history,
  erasure, and OpenSearch reindexing in the appropriate non-async tests.
