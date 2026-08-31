# ImageIntensities SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 9 (context functions, schema association, thumbnailer caller, image preloads, and duplicate-search consumer)

## Changed shapes

### Store derived intensities for an already-loaded image (`put_for_loaded_image` / `create_image_intensity`)

- Master: `lib/philomena/image_intensities.ex:39-43`, called by `lib/philomena/images/thumbnailer.ex`; builds an `image_intensities` row with `image_id` and four intensity values and issues a plain `INSERT`. The old context also exposed `get_image_intensity!/1`, `update_image_intensity/2`, and `delete_image_intensity/1`, but no application callers were found for those operations.
- context-logic: `lib/philomena/image_intensities.ex:28-35`, called by `lib/philomena/images/thumbnailer.ex:111-112`; same inserted columns and row source, but issues `INSERT ... ON CONFLICT (image_id) DO UPDATE SET nw, ne, sw, se RETURNING ...`.
- Delta: the write now has an upsert conflict lookup on `image_intensities.image_id`; row-selection predicates and inserted data are otherwise unchanged. This makes repeated thumbnail/intensity processing idempotent rather than failing on the existing row.
- Index status: covered.
- Evidence: both `master` and `context-logic` `priv/repo/structure.sql` define `index_image_intensities_on_image_id` as a unique B-tree on `(image_id)` (current structure around lines 3919-3922). That index is the exact arbiter for the new conflict target; the table also has the unchanged primary key and `image_intensities_index (nw, ne, sw, se)`. No additional index is indicated. The current branch adds only the image-delete cascade migration, which does not alter lookup shape or indexes.
- Confidence: high

## Unchanged or non-index-relevant sites

- `ImageIntensity` schema (`lib/philomena/image_intensities/image_intensity.ex:11-25`; master equivalent `:9-23`): same `image_intensities` table, `belongs_to :image` association, and required/unique changeset validation. The added `@type t` is compile-time only. The association has no custom `where` predicate.
- Image `has_one :intensity` association (`lib/philomena/images/image.ex:49`; master `:46`): unchanged relationship. Any Ecto preload query is a member lookup/association query of the form `SELECT ... FROM image_intensities WHERE image_id IN (...)`; it remains covered by the unique `(image_id)` index. It is used by featured/API/listing/merge preloads in `Images` and by duplicate search result preloads.
- Thumbnailer worker path (`lib/philomena/images/thumbnailer.ex:111-112`; master calls `create_image_intensity/2`): caller/function movement and the renamed context API do not change the row lookup shape; the only SQL delta is the upsert documented above.
- The intensity table's four-dimensional comparison index, `image_intensities_index (nw, ne, sw, se)`, exists identically in both refs. It remains the only non-unique intensity-value index.

## New, deleted, moved, or ambiguous sites

- Deleted public context helpers in `context-logic`: `get_image_intensity!/1`, `update_image_intensity/2`, `delete_image_intensity/1`, and their generated documentation. No callers exist in either ref, so these are deleted/unpaired API operations rather than removed workloads. `Repo.update`/`Repo.delete` on a loaded intensity would have used the row's primary-key identity in the old schema, but no runtime query site remains to audit.
- Moved/renamed write: `create_image_intensity/2` -> `put_for_loaded_image/2` is the same thumbnailer workload and is paired above.
- Duplicate comparison lookup is owned by `Philomena.DuplicateReports`, not this persistence context. `duplicate_reports.ex:55-88` in `context-logic` joins `images` to `image_intensities` on `intensity.image_id = image.id`, applies inclusive ranges on `nw`, `ne`, `sw`, `se`, and an image aspect-ratio range, orders by a computed squared-distance expression plus `image.id`, and limits results. The corresponding `master` query is `duplicate_reports.ex:63-91`: same join/ranges/aspect-ratio range and computed distance, but no `image.id` tie-breaker. This is an index-relevant ordering delta (and should be canonicalized in the DuplicateReports report); the existing `(nw, ne, sw, se)` index may help range filtering but cannot provide the computed distance order. The additional visibility predicates in current `generate_reports/1` and reverse-search `visible_images_query/1` are Images/DuplicateReports concerns, not ImageIntensities-owned queries.
- Reverse-search result preloads (`DuplicateReports` reverse search) load `:intensity` through the unchanged `Image.has_one` association; no separate intensity query definition exists in this context.

## Follow-ups

- Link the duplicate-comparison finding above from the DuplicateReports report and deduplicate any recommendation against its existing `image_intensities_index`. A generic new B-tree is not recommended here: four independent range predicates plus a calculated distance ordering require representative plans and workload evidence before considering specialized indexing.
- The upsert relies on the existing unique `image_id` index and adds no index candidate. If the old unused CRUD API is intentionally removed, verify external consumers separately; that is an API compatibility question, not a PostgreSQL index issue.
