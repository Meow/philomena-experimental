# SourceChanges SQL shape audit

Refs: master -> context-logic  
Status: complete  
Query sites inspected: 16

--- files ---

- `lib/philomena/source_changes.ex`
- `lib/philomena/source_changes/query_builder.ex`
- `lib/philomena/source_changes/query_form.ex`
- `lib/philomena/source_changes/source_change.ex`
- `lib/philomena/source_changes/source_change_page.ex`
- `lib/philomena/source_changes/attribution.ex`
- `lib/philomena/images.ex` (source-change count, writes, history deletion)
- `lib/philomena/images/image.ex` (source-change association/changesets)
- `lib/philomena/users/eraser.ex` and `lib/philomena/users/user_wipe.ex` (cleanup callers)
- `lib/philomena_web/controllers/{image,profile,ip_profile,fingerprint_profile}/source_change_controller.ex`
- `lib/philomena_web/controllers/image/source_controller.ex`
- `lib/philomena_web/controllers/image/source_history_controller.ex`
- `priv/repo/structure.sql` and source-change migration history

## Changed shapes

### Image source-change history page (`list_image_source_changes/4`)

- Master (`Image.SourceChangeController.index/2`): `source_changes WHERE image_id = ? ORDER BY id DESC`, with the same user/image/tags preloads, then pagination.
- context-logic (`SourceChanges.list_image_source_changes/4`): resolves and authorizes the image through `Images.load_visible_image/2`, applies optional `added = ?`, then `WHERE image_id = ? ORDER BY created_at DESC, id DESC`, with the same preloads and pagination.
- Delta: `created_at DESC` is a new ordering key (with `id DESC` tie-breaker); the optional `added` predicate is a new branch. Image visibility is applied while resolving the parent image, not to source-change rows. The query is a collection page.
- Index status: covered for filtering; no index action.
- Evidence: `index_source_changes_on_image_id` covers the equality lookup. The existing primary key covers the `id` tie-breaker, but no `(image_id, created_at DESC, id DESC)` index exists. A composite ordering index could reduce sorting for large histories, but no plan/workload evidence or table cardinality was available to justify its write/storage cost. `added` is a low-cardinality boolean and does not justify a standalone index.
- Confidence: high

### User source-change history page and distinct-image count (`list_user_source_changes/4`)

- Master (`Profile.SourceChangeController.index/2`): joins `source_changes` to `images` on `sc.image_id = i.id`; filters `sc.user_id = ?` and excludes rows where `i.user_id = ? AND i.anonymous = true`; applies optional `added = ?`; page query orders by `id DESC`; count query reuses the relation and selects `count(DISTINCT i.id)`.
- context-logic (`SourceChanges.list_user_source_changes/4`): same inner association join and predicates, with `QueryBuilder` adding the same optional `added` branch and `ORDER BY created_at DESC, id DESC`; the count explicitly `exclude(:order_by)` before `count(DISTINCT image.id)`.
- Delta: page ordering adds `created_at DESC`; aggregate SQL no longer carries the page order (an access-path/performance improvement, not a new filter). Join and visibility/exclusion predicates are unchanged. These are a collection page plus a distinct aggregate.
- Index status: covered; no index action.
- Evidence: `index_source_changes_on_user_id` covers the leading source-change filter, and `images.id` is the primary key for the join. The existing user index may still sort/filter residual rows, but no evidence supports `(user_id, created_at DESC, id DESC)` or a partial `added` variant. The distinct count necessarily joins and deduplicates images; a generic index recommendation would be speculative.
- Confidence: high

### IP/subnet source-change history page (`list_ip_source_changes/4`)

- Master (`IpProfile.SourceChangeController`): parses the IP, computes a mask range, then `source_changes WHERE range >>= ip`, optional `added = ?`, `ORDER BY id DESC`, preloads, and paginates.
- context-logic: validates/canonicalizes the IP before authorization, computes the same `IpMask.parse_mask/2` range, then uses `WHERE range >>= ip`, optional `added = ?`, `ORDER BY created_at DESC, id DESC`, preloads, and paginates.
- Delta: only the ordering key changed from `id DESC` to `created_at DESC, id DESC`; the `>>=` fragment, added branches, and preload shape are unchanged. This is a subnet collection page.
- Index status: existing index only; no candidate recommended.
- Evidence: `index_source_changes_on_ip` exists as ordinary B-tree, but the `>>=` containment operator is not a generic B-tree access path; a GiST/SP-GiST inet index might help, but requires representative `EXPLAIN` and workload/selectivity evidence. None was available, so no specialized index is proposed. The primary key covers the tie-breaker.
- Confidence: high

### Fingerprint source-change history page (`list_fingerprint_source_changes/4`)

- Master (`FingerprintProfile.SourceChangeController`): `source_changes WHERE fingerprint = ?`, optional `added = ?`, `ORDER BY id DESC`, preloads, and pagination.
- context-logic: trims/downcases/validates the fingerprint before authorization, then uses the same equality and optional `added` predicates, with `ORDER BY created_at DESC, id DESC`, preloads, and pagination.
- Delta: ordering adds `created_at DESC`; input normalization changes bind values only. This is a collection page.
- Index status: index gap observed, but no recommendation.
- Evidence: there is no `source_changes.fingerprint` index in either `priv/repo/structure.sql` or the migration history. An equality-leading `(fingerprint, created_at DESC, id DESC)` B-tree would fit this page, but frequency, cardinality, and representative plans were not established. Do not add it automatically; validate with production-like workload/`EXPLAIN` first. A standalone boolean `added` index is not justified.
- Confidence: high

## Unchanged or non-index-relevant sites

- `SourceChanges.count_for_image/1` is the moved image-controller count: `COUNT(*) FROM source_changes WHERE image_id = ?`. The image index covers it; the aggregate result mapping is unchanged.
- `SourceChanges.count_query/0` is the moved lateral count used by `Images.show_image/2`. Master's image loader already used the same correlated `WHERE image_id = parent_as(:image).id SELECT count(*)`; only ownership/composition changed. `index_source_changes_on_image_id` covers the correlation.
- `SourceChanges.erase_source_change/2` uses `Loader.fetch(SourceChange, id)` and `Multi.delete` by the source-change primary key. The image revert step locks/updates `images WHERE id = ?`; all are primary-key covered. This replaces the old generic CRUD API and is not a new lookup shape.
- `SourceChanges.put_record_image_changes/3` performs `insert_all` for added/removed rows. Inserts have no row-selection predicate or conflict target; no index recommendation follows.
- `SourceChanges.wipe_user_attribution!/3` moved the old user-wipe batch update into the context: batches select `source_changes WHERE user_id = ?` and `UPDATE ... SET ip = ?, fingerprint = ?` on those rows. Existing `index_source_changes_on_user_id` covers selection; changed ownership/result handling is not a shape delta.
- `Users.Eraser` still scans `SourceChange WHERE user_id = ? ORDER BY created_at DESC` before erasing rows. The caller now invokes `SourceChanges.erase_source_change/2`; the source-change scan's predicates/order are unchanged and is covered by the user index plus a sort.
- Source-change preloads remain association lookups by `image_id`/`user_id` with no schema-level `where` clause. The image/user/tag preload SQL is shared context behavior, not a SourceChanges-specific shape change.

## New, deleted, moved, or ambiguous sites

- The four controller-owned history queries were consolidated into `QueryBuilder` plus target-specific context functions. They are paired above; this is not four unrelated workloads.
- The old generic `get/create/update/delete/change_source_change` functions were removed. Their generic member lookup was not used by the history controllers; deletion is now an authorized, image-reverting transaction and is covered by primary keys.
- The old image show lateral source-count query moved to `SourceChanges.count_query/0`; it is paired above.
- No ambiguous SourceChanges SQL sites remain after searching both refs for `SourceChange`, `source_changes`, source-history controllers, `Repo` operations, preloads, and cleanup callers.

## Follow-ups

- No index candidate is recommended for this audit. Existing `image_id`, `user_id`, `ip`, and primary-key indexes cover the changed equality/member paths.
- Fingerprint history has no equality index, but the focused review defers this
  infrequent moderation workload to a possible OpenSearch migration. Image/user
  ordering composites and an inet GiST/SP-GiST alternative remain optional
  only if workload changes; no schema change is proposed now.
- The semantic/correctness changes are deliberate: history now has stable timestamp-plus-ID ordering; user count removes an unnecessary aggregate order; identity inputs are normalized and validated before authorization.
