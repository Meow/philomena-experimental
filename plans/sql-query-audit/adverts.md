# Adverts SQL shape audit

Refs: master -> context-logic
Status: complete

--- status ---

Audited the Adverts context, its deleted recorder, advert controllers and plug,
the shared Loader path used by moved callers, the advert image association
preload, and the advert branch of the S3 maintenance task. No application
code, migrations, or tests were changed.

--- top-level audit paths ---

- `lib/philomena/adverts.ex`
- `lib/philomena/adverts/{advert,restrictions,server,uploader}.ex` and deleted
  `lib/philomena/adverts/recorder.ex`
- `lib/philomena_web/controllers/{advert,admin/advert_controller}.ex` and
  `lib/philomena_web/controllers/admin/advert/image_controller.ex`
- `lib/philomena_web/plugs/advert_plug.ex`
- `lib/philomena/loader.ex`, `lib/philomena/images/image.ex`, and
  `lib/mix/tasks/upload_to_s3.ex`
- `priv/repo/structure.sql` and relevant advert migration history at both refs

Query sites inspected: 22 source/query paths across both refs

## Changed shapes

### `record_click/1` — active advert member lookup

- Master: `master:lib/philomena_web/controllers/advert_controller.ex:7-14`
  loaded an advert by route id through Canary's `load_resource` (a primary-key
  lookup, normalized as `adverts WHERE id = :id`) and then enqueued the click
  through `Adverts.record_click/1`.
- context-logic: `lib/philomena/adverts.ex:119-124` calls
  `Loader.fetch(live_adverts_query(), id)`. The final lookup is `adverts WHERE
id = :id AND live = true AND start_date < :now AND finish_date > :now`, with
  no join, grouping, ordering, or pagination, followed by the same asynchronous
  counter enqueue.
- Delta: added fixed `live` and active-date predicates to the member lookup.
  This is `changed, index-relevant` at the relational-shape level and also a
  correctness/visibility change: disabled, future, and expired adverts are no
  longer clickable.
- Index status: covered
- Evidence: `adverts_pkey` covers the equality lookup on `id`
  (`priv/repo/structure.sql:2750-2754`). The added predicates are residual
  checks after the unique primary-key lookup; the existing
  `(start_date, finish_date)` index is not needed for this one-row access path.
  No composite index is justified without a different, non-ID workload.
- Confidence: high

### `record_counters/1` — impression/click counter writes

- Master: deleted `master:lib/philomena/adverts/recorder.ex:17-18` issued two
  bulk `INSERT ... ON CONFLICT (id) DO UPDATE` statements, one for impressions
  and one for clicks. The conflict target was the advert primary key.
- context-logic: `lib/philomena/adverts.ex:47-51,378-382` issues one
  `UPDATE adverts SET <counter> = <counter> + :count WHERE id = :id` for each
  map entry, for both counter fields. `lib/philomena/adverts/server.ex:68-73`
  invokes this flush path.
- Delta: changed from two bulk upsert statements to row-targeted updates; the
  conflict target is replaced by the same `id = :id` row-selection predicate.
  This is `changed, likely not index-relevant`: the SQL command shape and
  batching changed, but no lookup column/operator changed and the access path
  remains primary-key covered. The current no-op behavior for absent ids is
  also different from the old insert/upsert attempt.
- Index status: covered
- Evidence: `adverts_pkey` covers the current update predicate and covered the
  old upsert conflict target (`priv/repo/structure.sql:2750-2754`). There are no
  advert foreign keys or alternate write lookup columns. The migration history
  and advert portions of the structure dump are unchanged between refs.
- Confidence: high

## Unchanged or non-index-relevant sites

- `random_live/0` and `random_live/1`, master
  `lib/philomena/adverts.ex:26-65` versus context-logic
  `lib/philomena/adverts.ex:34-41`, retain the same normalized shape: select
  from `adverts`, fixed `live = true`, `start_date < :now`, and
  `finish_date > :now`, caller-controlled `restrictions IN (:restrictions)`,
  `ORDER BY random() ASC`, and `LIMIT 1`. Both public branches pass through
  `Restrictions.tags/1`; in particular `Restrictions.tags([])` returns
  `['none']`, so `random_live/0` did not lose its restriction predicate. The
  existing ordinary B-tree indexes on `restrictions` and
  `(start_date, finish_date)` are present in both structure dumps
  (`priv/repo/structure.sql:3436-3446`). `ORDER BY random()` cannot use a normal
  B-tree, and no new index is recommended from this unchanged shape without
  representative plans and workload/cardinality evidence.
- The `random_live(image)` `Repo.preload(:tags)` at
  `lib/philomena/adverts.ex:86-91` is unchanged from
  `master:lib/philomena/adverts.ex:45-50`. The image `tags` association at
  `lib/philomena/images/image.ex:47-48` has no association `where` clause, so
  there is no Adverts-specific preload-shape delta.
- `list_adverts/2`, context-logic `lib/philomena/adverts.ex:142-150`, is the
  moved form of the master admin query at
  `master:lib/philomena_web/controllers/admin/advert_controller.ex:12-22`.
  Both select all advert columns, order by `finish_date DESC`, and pass the
  relation to `Repo.paginate` (count plus page `LIMIT/OFFSET` queries). No
  filter, join, grouping, preload, or ordering change occurred.
- `edit_advert/2`, `update_advert/3`, `delete_advert/2`, and
  `update_advert_image/3` use the shared `Loader.fetch_and_authorize` member
  lookup at `lib/philomena/adverts.ex:43-45,235-239,266-269,306-310,350-352`.
  Their master counterparts were Canary persisted-resource loads in
  `master:lib/philomena_web/controllers/admin/advert_controller.ex:9-10` and
  `master:lib/philomena_web/controllers/admin/advert/image_controller.ex:7-13`.
  Each remains a primary-key member lookup followed by authorization; malformed
  id parsing changes control flow before SQL, not the valid-id shape.
- `create_advert/3`, `update_advert/3`, `delete_advert/2`, and
  `update_advert_image/3` retain the same advert insert/update/delete row
  predicates under `Philomena.Multi` at
  `lib/philomena/adverts.ex:199-205,271-276,309-315,358-364`. The master
  direct `Repo.insert/update/delete` calls at
  `master:lib/philomena/adverts.ex:122-136,151-155,169-183,198-200` had the
  same row-selection requirements. Upload callbacks and moderation-log steps
  do not add an advert selection predicate.
- `lib/mix/tasks/upload_to_s3.ex:49-55` is unchanged from master. Its advert
  maintenance relation is `adverts WHERE image IS NOT NULL AND updated_at >=
:time`; `PhilomenaQuery.Batch.record_batches/2` adds the unchanged ID-keyset
  query (`id > :max_id ORDER BY id ASC LIMIT :batch_size`) and per-batch
  `id IN (...)` load. This is maintenance workload, not a context-logic delta.
- `record_impression/1` and the GenServer buffering path do not issue SQL;
  `Philomena.Adverts.Restrictions.tags/1` is pure in-memory classification.

## New, deleted, moved, or ambiguous sites

- `master:lib/philomena/adverts.ex:108` deleted `get_advert!/1`, whose only
  query was an unscoped `Repo.get!(Advert, id)`. No caller exists in the master
  application tree, and no reliable current counterpart exists; classify as
  `deleted/unpaired` dead API rather than an index-relevant workload.
- `master:lib/philomena/adverts/recorder.ex` was deleted, but its two query
  sites are paired with `record_counters/1` above. This is a changed write
  shape, not an unpaired workload.
- The public and admin advert controllers moved their query responsibilities to
  `Philomena.Adverts`; `lib/philomena_web/plugs/advert_plug.ex:17-21` remains a
  caller of the unchanged random-selection shapes and adds no SQL.
- No advert association `where` clause, advert worker query, `delete_all`,
  `exists?`, aggregate, or locking query was found beyond the sites listed
  above.

## Follow-ups

- Verify the intentional public behavior change in `record_click/1`: only
  currently live adverts can now redirect and enqueue a click.
- Counter flushing now performs one primary-key update per counter-map entry
  instead of two bulk upserts. Primary-key coverage is adequate, but workload
  measurements are needed to assess write amplification.
- `Loader.fetch/3` and `Loader.fetch_and_authorize/5` are shared helpers and
  should be linked to their canonical `shared.md` finding. The image-tag
  preload is shared with Images/Tags ownership.
- No representative `EXPLAIN (FORMAT JSON)` was run: no missing index is
  indicated by the changed shapes, and the random-order workload needs
  representative row counts/selectivity before any specialized index is
  proposed.
