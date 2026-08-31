# DnpEntries SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 16 logical sites (including DNP-owned preload, worker/transaction, and count paths)

## Changed shapes

### Admin listing: state-filter branch

- Master: `lib/philomena_web/controllers/admin/dnp_entry_controller.ex:12-16`, `index/2` with list `states`; base `dnp_entries`, `WHERE aasm_state IN (^states)`, then shared preload (`tag`, `requesting_user`, `modifying_user`), `ORDER BY updated_at DESC`, pagination.
- context-logic: `lib/philomena/dnp_entries/query_builder.ex:25-45`, `search_dnp_entries/1` and `maybe_filter_states/2`; same base/filter shape for non-empty `states`, followed by the same three preloads and ordering in `query_builder.ex:30-35`.
- Delta: query construction moved into `QueryBuilder` and is now combined with the form’s text branch; the relational shape of the explicit non-empty state branch is unchanged. The empty-state branch intentionally omits the state predicate.
- Index status: covered
- Evidence: `priv/repo/structure.sql` has partial B-tree `index_dnp_entries_on_aasm_state_filtered` for requested/claimed/rescinded/acknowledged, plus primary key and foreign-key indexes. Explicit arbitrary states such as listed/closed use the table/other available paths; no new index is justified from source inspection.
- Confidence: high

### Admin listing: text search

- Master: `lib/philomena_web/controllers/admin/dnp_entry_controller.ex:18-30`, `index/2` with `eq`; inner joins `dnp_entries.tag` and `dnp_entries.requesting_user`; `WHERE ilike(users.name, '%q%') OR ilike(tags.name, '%q%') OR ilike(dnp_entries.reason, '%q%') OR ilike(conditions, '%q%') OR ilike(instructions, '%q%')`; shared preloads; `ORDER BY dnp_entries.updated_at DESC`; pagination.
- context-logic: `lib/philomena/dnp_entries/query_builder.ex:31-37,47-62`, `search_dnp_entries/1` and `maybe_filter_text/2`; same two inner joins, same five-way OR leading-wildcard `ILIKE`, same preloads/order/pagination, but normally also `WHERE dnp_entries.aasm_state IN ('requested','claimed','rescinded','acknowledged')` from `QueryForm`’s default state value.
- Delta: index-relevant additional fixed state predicate in the text branch. This is also a semantic behavior change: admin text searches no longer include listed/closed entries when the default form state is applied. The current admin controller passes `params["eq"] || %{}` at `lib/philomena_web/controllers/admin/dnp_entry_controller.ex:9-15`; whether that preserves the intended states parameter is ambiguous and needs a controller/form follow-up.
- Index status: covered | needs specialized search analysis
- Evidence: the partial `index_dnp_entries_on_aasm_state_filtered` covers the added active-state predicate. `index_tags_on_name` and `index_users_on_name` are unique B-trees, but cannot efficiently serve the leading-wildcard `ILIKE`; the three DNP text columns also have no suitable ordinary index. Do not add a generic B-tree for this OR shape. If this workload is frequent, evaluate PostgreSQL trigram indexes or a dedicated search path with representative plans.
- Confidence: high

### Admin listing: default active branch

- Master: `lib/philomena_web/controllers/admin/dnp_entry_controller.ex:32-36`, `index/2` fallback; `WHERE aasm_state IN ('requested','claimed','rescinded','acknowledged')`, preloads, `ORDER BY updated_at DESC`, pagination.
- context-logic: `lib/philomena/dnp_entries/query_builder.ex:12-17,30-35,41-45`, default `QueryForm` plus `maybe_filter_states/2`; same normalized shape.
- Delta: moved/form-backed query; no relational change.
- Index status: covered
- Evidence: the existing partial B-tree `index_dnp_entries_on_aasm_state_filtered` exactly matches the fixed active-state predicate. Ordering by `updated_at DESC` is unchanged and is not independently recommended without workload/plan evidence.
- Confidence: high

### Active count

- Master: `lib/philomena/dnp_entries.ex:140-147`, `count_dnp_entries/1`; aggregate `COUNT(id)` over `dnp_entries WHERE aasm_state IN ('requested','claimed','acknowledged')` when authorized.
- context-logic: `lib/philomena/dnp_entries.ex:421-431`, `count_dnp_entries/1`; same filter and authorization branch, aggregate expressed as `COUNT(*)`.
- Delta: aggregate target expression changed from `COUNT(id)` to `COUNT(*)`; row-selection and access shape are unchanged, so this is changed, likely not index-relevant.
- Index status: covered
- Evidence: the existing partial active-state B-tree covers the predicate; primary key covers `id` in the master expression. No index action.
- Confidence: high

## Unchanged or non-index-relevant sites

- Public/current-user listings moved from `lib/philomena_web/controllers/dnp_entry_controller.ex:23-38` (master) to `lib/philomena/dnp_entries.ex:91-115` (context-logic). `list_dnp_entries/3` retains two branches: mine is `WHERE requesting_user_id = ^user.id`, preload tag, `ORDER BY created_at ASC`; public is `WHERE aasm_state = 'listed'`, inner join tags on `dnp_entries.tag_id = tags.id`, preload tag, `ORDER BY tags.name_in_namespace ASC`. `index_dnp_entries_on_requesting_user_id` and `index_dnp_entries_on_tag_id` cover the equality paths; the public listed-state predicate/order are unchanged and have no demonstrated missing path.
- Single-record loads for show/edit/update/transition moved from the resource-loading plugs in `lib/philomena_web/controllers/dnp_entry_controller.ex:16-21` and `lib/philomena_web/controllers/admin/dnp_entry/transition_controller.ex:7-14` (master) to `DnpEntries.load_authorized_dnp_entry/3` at `lib/philomena/dnp_entries.ex:73-75`. `Loader.fetch/3` uses `Repo.get` by primary key with `[:tag]` preload; same PK lookup and tag-PK follow-up query. Authorization now occurs after loading, which is a semantic/visibility workflow change but not a SQL shape change.
- New/edit tag selection moved from controller `Repo.get!(Tag, id)` at master `lib/philomena_web/controllers/dnp_entry_controller.ex:132-145` to `get_tag_from_params/1` at context-logic `lib/philomena/dnp_entries.ex:38-45` using `Loader.fetch/2`; both are tag primary-key lookups. `linked_tags/1` at `lib/philomena/dnp_entries.ex:30-36` retains the user `linked_tags` association preload (shared Users-owned query).
- Create/update changesets at `lib/philomena/dnp_entries.ex:227-253,298-323` and transition at `343-369` issue INSERT/UPDATE by the changeset’s primary-key identity. The Multi wrapping, authorization, and audit-log composition do not alter row-selection predicates. No DNP delete query remains paired with a current public operation; master’s `delete_dnp_entry/1` at `lib/philomena/dnp_entries.ex:110-112` was an unused record delete and has no current counterpart.
- `DnpEntry` association declarations at `lib/philomena/dnp_entries/dnp_entry.ex:10-23` are unchanged. `Tag.has_many(:dnp_entries, where: [aasm_state: "listed"])` at `lib/philomena/tags/tag.ex:80-83` is unchanged; its preload shape is `dnp_entries WHERE tag_id IN (...) AND aasm_state = 'listed'` and is consumed by tag/image/API paths. The DNP-owned foreign-key index on `tag_id` covers the join; the partial active-state index deliberately does not cover listed rows.
- The DNP count is also consumed by `PhilomenaWeb.AdminCountersPlug` (master/current call sites), while moderation-note target loading is a shared `ModNotes` query. These are linked here for coverage, not re-owned as DnpEntries findings.

## New, deleted, moved, or ambiguous sites

- `put_dnp_tags/3` at `lib/philomena/dnp_entries.ex:395-405` is a moved DNP validation query. Its master counterpart is `Philomena.Images.DnpValidator.validate_dnp/2` at `lib/philomena/images/dnp_validator.ex:8-22`: select tags by `tags.name IN (...)`, require `EXISTS (SELECT 1 FROM dnp_entries WHERE dnp_entries.tag_id = tags.id)`, then preload `dnp_entries` (association filter `aasm_state = 'listed'`) and each entry’s tag/verified links. Current execution is a `Multi.all` step rather than direct `Repo.all`; normalized SQL shape is unchanged. `index_tags_on_name` and `index_dnp_entries_on_tag_id` cover the lookup/EXISTS; the listed association additionally filters on state. This is moved, unchanged, and no index action is proposed without workload plans.
- `put_replace_tag/4` at `lib/philomena/dnp_entries.ex:378-386` owns `UPDATE dnp_entries SET tag_id = ^target WHERE tag_id = ^source` during tag aliasing. It is a context boundary for the tag alias workflow (`lib/philomena/tags.ex:1109-1120`); the DNP table update was not an independent master DnpEntries public function. The existing `index_dnp_entries_on_tag_id` covers the write target predicate. No candidate.
- `list_admin_dnp_entries/3` at `lib/philomena/dnp_entries.ex:132-148` has an invalid-query fallback `Repo.paginate(where(DnpEntry, false), ...)` at lines 142-144. This is a new safety/error path with no rows and no index requirement.
- `ModNotes.list_for_target/3` called by `show_dnp_entry/3` at `lib/philomena/dnp_entries.ex:167-177` issues the shared target query `mod_notes WHERE dnp_entry_id = ^id ORDER BY id DESC LIMIT 250`, then target preloads including `dnp_entry: [:requesting_user, :tag]`. Its partial `mod_notes_dnp_entry_id_index` at `priv/repo/structure.sql` covers the target lookup; ordering is unchanged from the master `list_all_mod_notes_for_target/2` path. Canonical ownership belongs in `shared.md`.

## Follow-ups

- Verify the admin controller’s `params["eq"] || %{}` handoff and how the admin form encodes `states`; direct `QueryBuilder` callers can request explicit states, but the current controller appears not to pass the top-level states list. Confirm intended semantics for text searches across listed/closed entries before treating the added active-state predicate as a correctness fix or regression.
- The active-state partial index exactly covers the default admin filter and count. No DNP-specific index candidate is supported by current schema evidence. A future trigram/search decision for the five-way leading-wildcard OR needs representative `EXPLAIN (FORMAT JSON)`, table cardinalities, and workload frequency; do not infer it from this audit alone.
- Shared findings to link: `Loader` PK/preload and authorization behavior; `ModNotes` target query; user `linked_tags` preload; tag association preload/visibility. No application code, migration, shared report, or summary was changed.
