# Filters context plan

Source: `lib/philomena/filters.ex`; consumers: HTML/API filter listing/search,
current/public filter actions, and tag hide/spoiler toggles.

## Implementation status

Complete for wave 4.

- Controller-facing collection, member, form, selection, and tag operations are
  Actor-first and action-specific. The new/edit loaders and every mutation use
  the same write-access prerequisite.
- `nil` now explicitly selects the canonical default filter. Malformed or
  missing non-null IDs return not-found, while a forbidden private selection
  resolves to the default. Forced-filter selection remains independent.
- Current/forced filter resolution moved out of plugs and into the context.
  System, personal, HTML, API, and search listings now share named abilities;
  moderator search visibility matches the existing member `:show` grant.
- Loaded-record persistence and tag modifiers are private. The four public tag
  toggles authorize the filter and safely load/authorize the tag. `TagList`
  storage remains unchanged as required.
- Filter deletion now translates both current-filter and forced-filter foreign
  key restrictions into rejected changesets. Mutation indexing remains queued,
  while worker reindex and user-rename services stay explicit public APIs.
- Context and controller tests cover default/nil selection, malformed, missing,
  foreign, system, current, and forced filters; write-access parity; all four tag
  toggles; invalid searches; indexed visibility; and HTML/JSON callers.

## Findings

- Early raw tag modifiers and changeset/query APIs duplicate later actor-scoped
  hide/spoiler functions, producing a broad mixed public surface.
- The `switch_current_filter/2` TODO calls `filter_for_switch(nil)` behavior
  “nonsense”: it looks up a sentinel `id: nil` row and treats IDs differently.
- Most member operations use Loader, but page/form operations vary in action and
  write-access checks; filter-tag authorization loads tags by slug separately.
- Search compile errors and public/system/user visibility are not expressed with
  one result contract.

## Work

- Decide the current-filter null contract: either `nil` means the canonical
  default filter returned directly, or require an explicit valid filter ID.
  Delete the impossible `id: nil` lookup and document the selected behavior.
- Make controller APIs actor-first and action-specific. Apply
  `verify_write_access/1` consistently to current-filter and tag mutations, then
  authorize both the filter and tag interaction.
- Consolidate raw and actor-scoped hide/spoiler functions into private modifier
  steps plus four documented public operations. Safely load tags and preserve
  filter ownership/system-filter restrictions in Ability.
- Normalize system/user/public/search listing visibility and query failures.
  Keep indexing/service APIs documented but separate from controller APIs.
- Reorder private CRUD/query/tag/indexing functions before public APIs; document
  forced-filter restrictions, default/current semantics, and reindex effects.
- For now, do NOT replace `Philomena.Schema.TagList`'s denormalized comma-string/ID-list tag storage.

## TODO resolution

- Remove sentinel-row switching behavior and replace it with an explicit default
  filter contract plus controller/context tests.

## Verification

- Test malformed/missing/foreign/system filter IDs, nil/default switching,
  forced filters, each tag toggle, invalid search queries, API visibility, and
  reindexing.
