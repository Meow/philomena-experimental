# Comments SQL shape audit

Refs: master -> context-logic
Status: complete

Query sites inspected: 27

## Changed shapes

### Image comment collection page (`list_image_comments/3`, formerly `CommentLoader.load_comments/2`)

- Master: `lib/philomena_web/comment_loader.ex:6-14`, base `comments`; fixed `image_id = ?`; for non-staff, `destroyed_content = false`; for signed-in users, `approved = true OR user_id = ?`; collection page ordered by `created_at ASC|DESC`; preloads `image`, `deleted_by`, and `user.awards.badge`.
- context-logic: `lib/philomena/comments.ex:254-260`, same base and `image_id` scope; `Comments.Visibility.visible_comments/2` adds independent `hidden_from_users = false` and `destroyed_content = false` branches plus `approved = true OR user_id = ?` for ordinary signed-in actors (or `approved = true` anonymously); ordered by `created_at ASC|DESC, id ASC|DESC`; same preloads plus nested image `sources` and `tags.aliases`.
- Delta: visibility now includes the comment's hidden flag (and applies the policy consistently), and the order has an ID tie-breaker. The preload set adds FK-driven follow-up queries.
- Index status: no index action; existing `index_comments_on_image_id_and_created_at (image_id, created_at)` covers the principal equality-plus-order access path, while the approval/visibility predicates include an `OR` and are not a generic B-tree candidate. The ID tie-breaker is a deterministic refinement of the existing prefix, not sufficient evidence for a new `(image_id, created_at, id)` index.
- Evidence: `priv/repo/structure.sql` is identical for the relevant comments indexes on both refs. No representative EXPLAIN was run because the application/database container was not required to complete this source/schema audit.
- Confidence: high

### Comment page locator/count (`list_comment_page/4`, formerly `CommentLoader.find_page/3`)

- Master: `lib/philomena_web/comment_loader.ex:16-34`; exact member lookup `image_id = ? AND id = ?`; count over the image-scoped collection with the same destroyed/approval filters, then a one-column created-at boundary (`created_at <= ?` for oldest-first or `>= ?` for newest-first).
- context-logic: `lib/philomena/comments.ex:286-298`; parent image and comment are loaded through `load_image/3` and `load_image_comment/5` (the latter builds `image_id = ? AND id = ?` through `Loader`); count uses `image_id = ?`, `Visibility.visible_comments/2`, and a keyset boundary `(created_at < ? OR (created_at = ? AND id < ?))` or the corresponding `>`/`>` branch.
- Delta: collection count gains hidden-comment filtering and uses the same approval semantics explicitly; boundary pagination adds an ID tie-breaker and changes inclusive comparison to strict comparison. The exact member lookup remains PK plus parent scope. These are index-relevant predicate/order changes and also a correctness/behavior change for hidden comments and same-timestamp rows.
- Index status: no index action; `comments_pkey` covers `id`, `index_comments_on_image_id` covers the parent scope, and `(image_id, created_at)` covers the dominant count/order prefix. The `OR` keyset boundary and approval/visibility branches need plan evidence before considering a specialized index.
- Evidence: comments indexes are unchanged between refs; no EXPLAIN/runtime dataset was available or necessary for this report.
- Confidence: high

### Final visible comment page (`last_comment_page/3`, formerly `CommentLoader.last_page/2`)

- Master: `lib/philomena_web/comment_loader.ex:36-44`; count over `comments` with `image_id = ?`, staff-dependent destroyed filtering, and signed-in approval exception.
- context-logic: `lib/philomena/comments.ex:309-315`; count over the same parent scope with `Visibility.visible_comments/2`, including hidden, destroyed, and approval predicates; page calculation is otherwise unchanged.
- Delta: adds the hidden-comment predicate and makes visibility policy explicit for this aggregate.
- Index status: no index action; `index_comments_on_image_id` covers the fixed parent equality, and the remaining boolean/`OR` predicates do not justify a generic index without workload evidence.
- Evidence: existing indexes in `priv/repo/structure.sql`; no EXPLAIN.
- Confidence: high

### Parent-scoped comment member loads and preloads (`load_image_comment/5` and `show_comment/2`)

- Master: `lib/philomena_web/plugs/load_comment_plug.ex:13-20` and `lib/philomena_web/controllers/api/json/comment_controller.ex:8-16`; `comments` lookup by `id = ?` (the plug additionally supplies `image_id = ?`), followed by application-level hidden/destroyed/image checks. Preloads are caller-specific.
- context-logic: `lib/philomena/comments.ex:41-46,184-188,356-358`; parent-scoped lookup is `image_id = ? AND id = ?` through `Loader.fetch_and_authorize`, while global API lookup remains `id = ?`; authorization is performed after load for the comment and image. The standard preload set is expanded to include image sources/tags/aliases, deleted-by user, and user awards/badge.
- Delta: lookup predicates are unchanged or strengthened by retaining the parent scope; visibility checks move into authorization rather than SQL row predicates. Added association preloads issue FK/PK lookups but do not change the comments table access path.
- Index status: covered; `comments_pkey`, `index_comments_on_image_id`, and the existing association indexes/PKs cover the lookups. No new association `where` clause exists: `Image.has_many :comments` and `Comment.has_many :reports` are unfiltered.
- Evidence: schema definitions in `lib/philomena/images/image.ex` and `lib/philomena/comments/comment.ex`; relevant comments indexes are unchanged in both structure dumps.
- Confidence: high

### Comment update locking and version existence check (`update_comment/4`, `Versions.record_edit/5`)

- Master: `lib/philomena/comments.ex:88-99` updates the already-loaded comment by PK and calls `Versions.record_edit/4`; `lib/philomena/versions.ex:44-61` tests `comment_versions.comment_id = ?` with `repo.exists?`, then inserts version rows.
- context-logic: `lib/philomena/comments.ex:510-521,664-676` adds `comments.id = ?` with `preload(:user)` and locks both parent `images.id = ?` and comment `id = ?` before updating; `lib/philomena/versions.ex:24-42,55-66` retains the same `comment_versions.comment_id = ?` existence lookup and inserts only for meaningful edits.
- Delta: new row locks and the user preload are added to serialize parent/comment workflows; the version existence predicate and version ordering shape are unchanged. Lock lookup columns remain primary keys.
- Index status: covered; `comments_pkey`, `images_pkey`, and `comment_versions_comment_id_created_at_index (comment_id, created_at)` exist on both refs. No candidate.
- Evidence: `priv/repo/structure.sql`; `comment_versions` indexes originate from `20260716190444_normalize_versions.exs` and are unchanged for these columns.
- Confidence: high

### Comment migration and attribution wipe (`put_migrate_image_comments/3`, `wipe_user_attribution!/3`)

- Master: `migrate_comments/2` updates `comments` where `image_id = ?`, then updates the target image by `id = ?`; the context also exposes batch reindex queries by a trusted dynamic column and `IN` list.
- context-logic: `put_migrate_image_comments/3` keeps the comments update `image_id = ?` but composes it into `Philomena.Multi`; target image counter maintenance moved to the Images-owned workflow. `wipe_user_attribution!/3` adds a batched update where `user_id = ?`; `perform_reindex/2` retains `field(column) IN (?)`.
- Delta: comment migration is moved/composed, not reshaped. Attribution wipe is a moved caller/workflow site with the same user equality update shape. Reindex is outside the SQL-shape scope when used for search serialization, although its base Ecto selection remains an `IN` predicate.
- Index status: covered/no index action; `index_comments_on_image_id` and `index_comments_on_user_id` cover the mutation selectors. Primary-key image counter updates are covered. The dynamic reindex selector is workload-dependent and not an application SQL-shape change.
- Evidence: structure dump indexes on both refs; `Philomena.Users.UserWipe` is the moved caller and owns the surrounding user-row selection.
- Confidence: high

## Unchanged or non-index-relevant sites

- `create_comment/3`: image lock and image counter selection remain by `images.id`; insertion has no row-selection predicate. The new `Philomena.Multi`/`lock_one` composition is a transaction/locking refactor with PK coverage.
- `create_comment_hide/4`, `delete_comment_hide/3`, `create_comment_delete/3`, and `create_comment_approve/3`: comment updates remain PK-targeted; the new parent image and locked-comment lookups are PK/parent-scoped and covered. Report closure queries belong to Reports/shared follow-up.
- `Versions.for_comment/1`: `comment_versions.comment_id = ? ORDER BY created_at DESC, id DESC LIMIT 26` is the same shape as the old `load_comment_versions/1`; `comment_versions_comment_id_created_at_index` covers the leading equality/order access path. The ID tie-breaker was already present in both refs.
- `Comment` and `CommentVersion` schema association declarations add no SQL-affecting `where` clauses. Added `Comment.has_many :reports` is unfiltered.
- `Comments.Query`, `Comments.Visibility.search_exclusions/3`, and `Comments.SearchIndex` OpenSearch request/mapping/serialization logic are excluded by the plan; they are not PostgreSQL SQL shapes.
- `new_comment_changeset/0`, changeset validation, reindex enqueue operations, and post-commit notifications do not issue row-selection SQL owned by Comments.

## New, deleted, moved, or ambiguous sites

- `PhilomenaWeb.CommentLoader` and `PhilomenaWeb.LoadCommentPlug` were deleted. Their database-backed collection, count, member, and preload sites are paired above with `Comments.list_image_comments/3`, `list_comment_page/4`, `last_comment_page/3`, and `load_image_comment/5`.
- The old global API member lookup was paired with `Comments.show_comment/2`; the old post-load hidden/destroyed checks are now authorization decisions, not SQL predicates.
- `Philomena.Users.UserWipe` now calls `Comments.wipe_user_attribution!/3`; the caller's user-comment enumeration is Users-owned and is a linked follow-up, not duplicated here.
- Image counter updates and comment migration orchestration moved between Comments and Images. The comments-table update remains `image_id = ?`; the Images-owned counter update remains an image primary-key mutation.
- No required ref, schema, or source file was unavailable. Runtime EXPLAIN evidence was not collected because this source/schema audit did not require starting the compose database.

## Follow-ups

- Link shared findings for `Philomena.Loader` authorization/fetch behavior, `Philomena.Multi` lock/update helpers, and Reports report-closure queries when the coordinator reconciles `shared.md`; these are not duplicated as Comments index candidates.
- The newly explicit hidden-comment predicate and strict ID tie-breaker change behavior beyond indexing. Confirm that the intended public image-comment policy is to exclude `hidden_from_users` rows and that strict keyset pagination matches the UI's page semantics.
- If production plans show the visibility-filtered image comment page/counts are hot, evaluate a workload-specific partial/composite strategy. Do not add a generic index solely for `approved`, `hidden_from_users`, or `destroyed_content` because the signed-in approval branch contains `OR user_id = ?` and the current `(image_id, created_at)` index already covers the principal access path.
