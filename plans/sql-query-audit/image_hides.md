# ImageHides SQL shape audit

Refs: master -> context-logic  
Status: complete
Query sites inspected: 9 (personal hide transactions, merge inserts,
interaction union branch, association preloads, exports, and moved callers)

## Scope and source set

Owned schema/context:

- `lib/philomena/image_hides.ex` (current lines 18-99; master lines 16-53)
- `lib/philomena/image_hides/image_hide.ex` (unchanged)

Moved callers and shared consumers reviewed in both refs:

- `lib/philomena/images.ex` (the personal hide API now composes
  `ImageHides` transaction steps; the image counter helper is in `Images`)
- `lib/philomena/interactions.ex` (user interaction lookup, image association
  preloads, and merge migration)
- `lib/philomena/images/image.ex` (`has_many :hides` and `:hiders`)
- `lib/philomena/data_exports/aggregator.ex` (user export stream)
- the old/current `PhilomenaWeb.Image.HideController` callers

No `ImageHide` query exists in the schema changeset itself. The changeset only
declares the existing composite uniqueness constraint.

## Changed shapes

## Normalized query shapes

### Personal hide replacement and deletion

`delete_hide_steps/3` in current and `delete_hide_transaction/2` in master
issue the same delete shape:

```text
DELETE FROM image_hides
WHERE image_id = :image_id AND user_id = :user_id
```

The current implementation uses this query both for a hide replacement and for
an explicit unhide. Master used it for the controller's explicit delete and
also as the first half of the controller's replacement transaction. This is a
workload/composition change, not a relational-shape change. Both predicates
are fixed equality predicates; there are no joins, ordering, grouping,
pagination, or locks.

Both refs then update exactly one image row:

```text
UPDATE images
SET hides_count = hides_count + :delta
WHERE id = :image_id
```

Master expressed this as `Multi.update_all` for create and a `Multi.run`
containing `repo.update_all` for delete. Current uses
`Images.put_image_counter_delta/5`, whose implementation still emits
`repo.update_all(where(Image, id: ...), inc: ...)` (current
`lib/philomena/images.ex:1343-1350`). The callback-derived delta and the
transaction step placement do not change the row-selection shape; the primary
key covers it.

The current replacement operation additionally emits the same two statements
in this order: delete matching hide, update image by primary key, insert one
`image_hides` row, update image by primary key. Master emitted insert/update for
create after a preceding delete/update transaction append. The insert has no
row-selection predicate; `on_conflict` is not used for the personal replacement
insert.

Classification: `unchanged` for the paired delete and image-update shapes;
transaction ordering and idempotent counter handling are not index shape
changes. The current API's image member load/authorization occurs in
`Images.load_image_member/4` before these steps; that locator belongs to the
Images audit.

### Merge interaction migration

Master's `Interactions.migrate_interactions/2` and current
`ImageHides.put_migrate_image_interactions/2` both perform a bulk insert of
source hiders onto the target:

```text
INSERT INTO image_hides (image_id, user_id, created_at)
VALUES (...), ...
ON CONFLICT DO NOTHING
```

Master ran this in a newly-created `Multi`; current runs it as the
`:interaction_hides` step in the caller's `Philomena.Multi`. The current source
snapshot is preloaded through `Image.hiders`, and the conflict target remains
the database's existing unique `(image_id, user_id)` index. No lookup/filter,
join, order, aggregate, or lock shape was added. The changed step name and
counter accounting are not index-relevant.

Classification: `unchanged` (bulk insert/conflict shape), with transaction
composition changed but no access-path change.

### User interaction lookup (shared `Interactions` workload)

For a non-anonymous actor and non-empty image ID list, the hide arm in both
refs is one branch of a `UNION ALL` query:

```text
SELECT image_id, user_id, 'hidden', ''
FROM image_hides
WHERE image_id IN (:image_ids) AND user_id = :user_id
UNION ALL ... -- faves and up/down votes
```

Current changes the public argument order to actor-first, normalizes nested
inputs, deduplicates IDs as before, and skips the query for anonymous/empty
inputs. The hide branch's base table, selected columns, two equality/IN
filters, and union semantics remain the same. The union construction is
reassociated (`union_all` reduction), but this does not alter the relational
access requirements.

Classification: `changed, likely not index-relevant` for the control-flow and
union-builder changes; the non-empty hide SQL shape is unchanged. This shared
finding should also be linked from `shared.md` if the coordinator records
shared workloads there.

### Image `hides`/`hiders` preloads

`Image.has_many(:hides, ImageHide)` is unchanged and has no association
`where` clause. The preload query is therefore the standard Ecto association
load:

```text
SELECT ... FROM image_hides
WHERE image_id IN (:loaded_image_ids)
```

The through association `:hiders` adds the normal join to `users` on
`image_hides.user_id = users.id`; neither join nor predicate changed between
refs. The current merge path uses `Repo.preload(..., force: true)` while the
master path used the default preload option; that affects cache reuse only,
not SQL shape.

Classification: `unchanged` (including association query and join). This is a
shared preload used by `Interactions` and image interaction pages.

### User data export

`DataExports.Aggregator` has the same ImageHide entry in both refs:
`{ImageHide, [:image_id], :user_id, :image_id}`. The generic exporter emits a
user-keyed stream and `Batch.records(id_field: :image_id)`. Its representative
shapes are:

```text
-- batch ID discovery
SELECT image_id FROM image_hides
WHERE user_id = :user_id AND image_id > :last_id
ORDER BY image_id ASC LIMIT :batch_size

-- batch fetch
SELECT created_at, image_id FROM image_hides
WHERE user_id = :user_id AND image_id IN (:batch_ids)
```

Classification: `unchanged`. This is a shared/data-export consumer rather
than a moved ImageHides API query.

## Unchanged or non-index-relevant sites

The association preload, interaction union branch, and user export retain the
same predicates and are recorded above as unchanged workloads.

## Index evidence and recommendations

`priv/repo/structure.sql` is identical for this table/index set in both refs:

- `index_image_hides_on_image_id_and_user_id`: unique B-tree
  `(image_id, user_id)`;
- `index_image_hides_on_user_id`: ordinary B-tree `(user_id)`;
- foreign keys from `image_hides.image_id` to `images.id` and
  `image_hides.user_id` to `users.id`.

Coverage:

- `(image_id, user_id)` delete, interaction lookup, insert conflict checking,
  and image preload are covered by the unique composite index (the leading
  `image_id` supports image-keyed preloads and the full pair supports exact
  lookups/deletes).
- User export and user-keyed interaction access are covered by the
  `user_id` index; the batch's `image_id` ordering is an additional sort/range
  concern, but no changed query introduced it and the export workload is
  unchanged.
- Image counter updates use the `images` primary key and need no ImageHides
  index.

No new index candidate. There is no changed filter, join predicate, ordering,
grouping, pagination, or write target predicate lacking existing coverage.
An `image_hides(user_id, image_id)` covering/order index could only be a
workload-driven optimization for the unchanged export path; the plan's
evidence threshold is not met here, and it should not be proposed as a
context-logic shape delta.

## New, deleted, moved, or ambiguous sites

The old transaction functions moved into loaded-image steps and the merge
insert moved into this owner; no ambiguous ImageHides SQL site remains.

## Follow-ups

The current personal hide operation deliberately deletes first and reinserts,
so repeated hides are idempotent and counter deltas are based on affected-row
counts. The current merge migration copies only rows absent at the target via
`ON CONFLICT DO NOTHING`; this matches the existing unique constraint and is
not a query-shape regression.
