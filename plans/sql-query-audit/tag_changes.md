# TagChanges SQL shape audit

Refs: master -> context-logic  
Status: complete

Query sites inspected: 8

## Scope and evidence

Reviewed `lib/philomena/tag_changes.ex`, all nested TagChanges modules,
`lib/philomena/workers/tag_change_revert_worker.ex`, the TagChanges callers in
Images/Tags and the old TagChange controllers, plus the tag-change portions of
`priv/repo/structure.sql` and migration `20250507183410_tag_changes_to_batches`.
OpenSearch query bodies (`Query`, `QueryBuilder`, `SearchIndex`) are not
PostgreSQL query shapes; their Ecto preloads are included below.

## Query-shape inventory

| Operation / owner                                                                                                 | Normalized shape in `master`                                                                                                                                                                                       | Normalized shape in `context-logic`                                                                                                                                                                   | Classification / index action                                                                                                                                                                                                                                                                                            |
| ----------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Selected-ID mass revert (`TagChanges.mass_revert` moved into `revert_tag_change_ids`; worker calls it indirectly) | `SELECT tag_changes` joined to `images` on `images.id = tag_changes.image_id`, `tag_changes.id IN (...)`, `images.hidden_from_users = false`, ordered by `tag_changes.created_at DESC`; preload join rows and tags | Same base join and predicates; order is `created_at DESC, id DESC`; preload is the renamed `tag_change_tags` association, issuing the same join-table-by-`tag_change_id` and tag-ID follow-up queries | **changed, index-relevant** only because of the deterministic `id` tie-breaker. ID filtering is PK-covered and the selected-ID batch is bounded; no new index recommended. Existing `tag_changes_image_id_index`, `tag_change_tags_tag_change_id_tag_id_index`, and `tag_change_tags_tag_id_index` cover joins/preloads. |
| Empty-history cleanup (`delete_empty_tag_changes` -> `cleanup_empty_for_tag_deletion`)                            | `DELETE FROM tag_changes WHERE NOT EXISTS (SELECT 1 FROM tag_change_tags WHERE tag_change_tags.tag_change_id = tag_changes.id)`, returning deleted rows for search cleanup                                         | Same anti-existence predicate; selects/returns only `id` (`RETURNING id`) and deletes via `Repo.delete_all`                                                                                           | **changed, likely not index-relevant**: result projection/returning changed, not row selection. The correlated lookup is covered by the leading `tag_change_id` column of the unique `(tag_change_id, tag_id)` index.                                                                                                    |
| Count history for an image (`count_tag_changes(:image_id, id)` moved to `count_for_image`)                        | `tag_changes` filtered by `image_id = ?`, left-joined to `tag_change_tags` by FK, returns `COUNT(DISTINCT tag_changes.id)` and `COUNT(tag_change_tags)`                                                            | Same fixed `image_id = ?` filter and left join, same two counts; also exposed as a parent-correlated lateral query (`tag_changes.image_id = parent image.id`) for image listings                      | **changed, index-relevant** (operation was specialized and added as a lateral consumer), but covered: `tag_changes_image_id_index` handles the outer filter and `(tag_change_id, tag_id)` handles the join. No candidate.                                                                                                |
| Tag-change ID cleanup/reindex Multi (`Tags` caller -> `put_delete_tag_change_tags`)                               | No equivalent context helper; tag deletion selected/deleted legacy association rows by caller-built query                                                                                                          | `Multi.all` selects `tag_change_id` from caller query, then `Multi.delete_all` on that same query, followed by reindex                                                                                | **new/deleted/unpaired** helper behavior, but no new predicate: access path is inherited from the caller query and the join table's existing indexes. No candidate.                                                                                                                                                      |
| Batch creation (`create_tag_change` -> `put_tag_change` / `put_batch_tag_changes`)                                | Insert one `tag_changes` row, then `INSERT` association rows for added/removed tags                                                                                                                                | Equivalent inserts, now transaction-composed; bulk path uses `insert_all` for both `tag_changes` and `tag_change_tags`                                                                                | **changed, likely not index-relevant**: writes have no row-selection predicate. Existing unique join index enforces the same conflict/uniqueness requirement.                                                                                                                                                            |
| Attribution wipe (`TagChanges.wipe_user_attribution!`)                                                            | No TagChanges-local counterpart in `master` (old callers did not own this write)                                                                                                                                   | Batched `UPDATE tag_changes SET ip = ?, fingerprint = ? WHERE user_id = ?`, batches by `image_id`                                                                                                     | **new/deleted/unpaired** workload. The equality predicate is covered by `tag_changes_user_id_index`; batching by image ID does not add a selection predicate. No candidate.                                                                                                                                              |
| Full-revert worker selectors (`TagChangeRevertWorker`)                                                            | `WHERE user_id = ?` / `ip = ?` / `fingerprint = ?`, then `Batch.query_batches` by `image_id`; each batch selects IDs and calls mass revert                                                                         | Same three selectors and image-ID batching; query execution moved into `TagChanges.revert_all_for_worker`                                                                                             | **unchanged** relational shapes (moved). Existing user/fingerprint B-trees cover equality selectors. The `ip` index is existing GiST (`inet_ops`) and covers IP lookup.                                                                                                                                                  |
| Search-result record preloads (`TagChanges.load` moved to `search_tag_changes`)                                   | Search result IDs are followed by Ecto preloads for user, image, image's user/sources/tags/aliases, and change-tag rows/tags                                                                                       | Same SQL preload relationships under renamed `TagChangeTag`; adds selected image visibility field for serialization                                                                                   | **changed, likely not index-relevant**: movement/association schema rename and selected columns do not change access requirements.                                                                                                                                                                                       |

## Index inventory and recommendations

Both refs contain the same relevant indexes in `priv/repo/structure.sql`:

- `tag_changes` primary key on `id`;
  `tag_changes_user_id_index` (B-tree `user_id`);
  `tag_changes_image_id_index` (B-tree `image_id`);
  `tag_changes_fingerprint_index` (B-tree `fingerprint`); and
  `tag_changes_ip_inet_ops_index` (GiST `ip inet_ops`).
- `tag_change_tags_tag_change_id_tag_id_index` (unique B-tree, leading
  `tag_change_id`) and `tag_change_tags_tag_id_index` (B-tree `tag_id`).
  The foreign keys from both join columns are therefore also covered for the
  TagChanges query paths.

No additional index candidate is recommended. The only ordering delta is an
`id` tie-breaker on an already ID-filtered revert batch, where a composite
`(created_at, id)` index would add write/storage cost without a demonstrated
workload benefit. No representative `EXPLAIN` was run; the repository does not
provide a production-sized database plan in this read-only audit, and all
changed relational predicates have direct existing index coverage.

## Semantic/correctness notes

The refactor changes the model from one tag-change row per tag assignment to a
batch row plus `tag_change_tags` join rows. The SQL table used for the
association remains `tag_change_tags`; the apparent association rename is not
a missing-parent-scope regression. Current selected-ID reversion explicitly
adds `id DESC` as a tie-breaker and filters hidden images as before. The new
profile/image/tag/IP/fingerprint listing APIs query OpenSearch, so their
visibility and resource filters are outside this PostgreSQL shape audit.
