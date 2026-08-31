# ImageVotes SQL shape audit

Refs: master -> context-logic  
Status: complete
Query sites inspected: 10 (per-image replacement/deletion, user cleanup
batches, merge inserts, interaction branches, preloads, workers, and callers)

--- files ---

- `lib/philomena/image_votes.ex`
- `lib/philomena/image_votes/image_vote.ex`
- `lib/philomena/interactions.ex` (migration caller; the vote insert moved into ImageVotes)
- `lib/philomena/user_downvote_wipe.ex` (master owner of cleanup)
- `lib/philomena/users/user_downvote_wipe.ex` (context-logic owner of cleanup)
- `lib/philomena/images.ex` (vote/fave transaction callers and counter helpers)
- `lib/philomena/workers/user_unvote_worker.ex`
- `lib/philomena_web/controllers/image/vote_controller.ex`
- `lib/philomena_web/controllers/image/fave_controller.ex`
- `lib/philomena_web/controllers/image/tamper_controller.ex`
- `lib/philomena_web/controllers/admin/user/vote_controller.ex`
- `lib/philomena_web/controllers/admin/user/downvote_controller.ex`
- `test/philomena_web/controllers/image/vote_controller_test.exs`
- `test/philomena/users_test.exs`
- `priv/repo/structure.sql`

## Relation and index inventory

`image_votes` has columns `(image_id, user_id, up, created_at)` and no
additional visibility or authorization predicates. The table has no declared
PostgreSQL primary-key constraint; both refs have the same indexes: the unique
composite `(image_id, user_id)` index
(`index_image_votes_on_image_id_and_user_id`), and
`index_image_votes_on_user_id (user_id)`. There are no partial, expression,
GIN/GiST, or `(user_id, up, image_id)` indexes. Foreign keys are
`image_id -> images(id)` and `user_id -> users(id)`.

## Changed shapes

## Query-shape comparison

### Per-image vote replacement and deletion

Master's `create_vote_transaction(image, user, up)` inserts one
`image_votes` row, then updates `images` by `images.id = ^image.id`, and
increments the user's statistics row through `UserStatistics`. It does not
delete an existing vote first; uniqueness on `(image_id,user_id)` therefore
causes a duplicate/revote conflict.

In context-logic, `put_vote_for_loaded_image/4` first issues two
`DELETE FROM image_votes` shapes, each with fixed equality predicates
`image_id = ^image.id AND user_id = ^user.id` and respectively `up = true` or
`up = false`; it then inserts the replacement row. It updates the image in
three separate `UPDATE images ... WHERE id = ^image.id` operations (one each
for upvotes, downvotes, and score), and updates user statistics. The
controller-facing caller now loads/authorizes the image before entering this
transaction, but that load is an Images/Loader query rather than an ImageVotes
query.

`delete_vote_transaction/2` in master has the same two per-direction delete
shapes followed by one image update by primary key. The current
`delete_vote_for_loaded_image/3` retains those delete predicates and performs
three image updates by primary key via `Images.put_image_counter_delta/5`.

Classification: **changed, index-relevant (workload shape), covered** for the
vote-row deletes: the current replacement path adds deletes before insert and
the current delete path remains two deletes. The lookup predicate itself is
covered by the existing unique `(image_id,user_id)` index; `up` is a residual
filter, and no new index is proposed. The image updates are
**changed, likely not index-relevant**: all use the existing image primary key
and only the number of updates changed. The user-statistic updates are
likewise primary/unique-key lookups and are covered.

No locking query is used in either implementation. The loaded-image lock and
authorization path introduced in context-logic belongs to `Images`/`Loader`,
not this context.

### User vote cleanup / batch deletion

Master's `UserDownvoteWipe` builds, for each direction, the base relation:

```text
image_votes WHERE user_id = ^user.id AND up = ^direction
```

It passes that relation to `Batch.query_batches(id_field: :image_id)`. Each
batch first selects `image_id`, ordered/advanced by `image_id` in batches,
then deletes rows matching the original `user_id`, `up`, and the batch's
`image_id IN (...)` predicate. The same base and batch relation now live in
`ImageVotes.delete_user_votes!/2`; the current implementation additionally
executes an explicit `SELECT image_id` for each batch before
`Repo.delete_all(batch)` so it can return affected IDs. Direction remains a
fixed equality branch (`up=true` or `false`).

Classification: base cleanup relation and batch/delete predicate are
**unchanged** semantically (moved from the Users-adjacent worker to
ImageVotes), while the explicit ID select is a **new/unpaired supporting
query** required by the return value. It has the same filters and batch
ordering as the existing batch-ID loader and introduces no new lookup column.
The old worker's image/user counter updates were moved to owning contexts;
those updates use image/user primary keys or `id IN (...)` and are not
ImageVotes index candidates.

The existing `image_votes_on_user_id (user_id)` index covers the leading
cleanup filter. The `up` predicate and `image_id` batch ordering are not fully
covered by a single current index. A possible candidate is `(user_id, up,
image_id)` for direction-specific cleanup and ordered batch ID extraction. The
focused production review instead requests replacing the standalone user
index with `(user_id, image_id)`, leaving `up` residual; compare both
definitions with representative plans before migration. Drop the standalone
index only after repository-wide usage and index-build checks.

### Interaction migration inserts

Master's `Interactions.migrate_interactions/2` creates two in-memory row
lists for up/down votes and executes `insert_all(ImageVote, rows,
on_conflict: :nothing)` for each. Context-logic moves this operation to
`ImageVotes.put_migrate_image_interactions/4`; it derives the same source
voter lists, inserts the same `(image_id,user_id,up,created_at)` rows with
`on_conflict: :nothing`, and adds `returning: [:user_id]` so user statistics
can be incremented only for rows inserted. The conflict target remains the
existing unique `(image_id,user_id)` key.

Classification: **changed, likely not index-relevant**. The relational
insert/conflict shape and target columns are unchanged; `RETURNING` changes
result materialization only. The operation is moved and now participates in
the owning transaction/counter composition. Existing unique-key coverage is
adequate.

### Schema associations and reads

`ImageVote` has only `belongs_to :user` and `belongs_to :image`; no association
`where`, ordering, or preload query changes exist between refs. There is no
ImageVotes-owned collection listing, aggregate/count, or existence query in
either ref. Interaction listings and association preloads are owned by
`Interactions`/`Images`; they should be linked from the shared or owning
context reports rather than counted as additional ImageVotes query shapes.

## Unchanged or non-index-relevant sites

The schema associations, image counter updates, user-stat updates, and
conflict-target materialization described above retain their existing
selection predicates and indexes.

## New, deleted, moved, or ambiguous sites

The user cleanup and interaction migration moved from adjacent owners into
ImageVotes but remain paired with the master workloads above; no ambiguous
ImageVotes SQL site was found.

## Recommendations

- Production review confirms a user-cleanup index follow-up. The requested
  replacement is `(user_id, image_id)`, which covers user equality and batch
  ordering while leaving `up` residual; compare it with `(user_id, up,
image_id)` using representative `EXPLAIN (ANALYZE, BUFFERS)` before choosing
  the definition. Drop the standalone user index only after checking
  repository-wide usage and write/storage cost.
- Changed query shapes that need no index action: primary-key image counter
  updates, user-statistic updates, migration `RETURNING`, and the moved
  ImageVotes transaction APIs.

## Follow-ups

The cleanup index is confirmed by production review, but compare the requested
two-column `(user_id, image_id)` replacement with the three-column variant on
representative plans and capture index size/build/write cost before migration;
no application-code change is part of this audit.
