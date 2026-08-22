# TagChanges context plan

Source: `lib/philomena/tag_changes.ex`; consumers: change list and single/full
revert controllers, workers, indexing, and user erasure.

## Implementation status

Complete for wave 4.

- The generic `load/3` boundary is replaced by global, image, tag, user, IP,
  and fingerprint history APIs. Each resource API resolves its target through
  the owning context before OpenSearch runs and returns a typed
  `TagChangePage`; tag aliases resolve to their canonical tag.
- Route resources and `tcq` are independent filters that compose in one bool
  query. A schema-backed query form validates query and sort input, adds a
  deterministic ID tie-breaker, and selects sensitive query fields through the
  shared identity-metadata ability rather than role strings.
- Search documents now carry image visibility. Global and resource-scoped
  history exclude hidden-image rows for ordinary viewers, while authorized
  staff retain review access. Malformed or absent resource locators are
  not-found, and valid forbidden IP/fingerprint targets are unauthorized.
- Tag-change creation is an Images-owned `Philomena.Multi` composition step
  with indexing after commit. Member deletion safely loads before action
  authorization, atomically writes its audit log, handles anonymous authors,
  and deletes the search document after commit.
- Empty rows left by tag deletion are removed by one explicit query returning
  their IDs for search cleanup. Image counts, image-batch reindexing, worker
  reversion, and index projection remain narrow documented service APIs; the
  old raw create/reindex/mass-revert functions are private or removed.
- Full-revert targets are validated and normalized before enqueue, exactly one
  target is required, and its audit log commits before the worker job is
  released. Worker batches stay grouped by image and surface failures instead
  of silently continuing.
- Context and controller coverage pins every resource type, query validation,
  authorization, hidden-image visibility, aliases, deterministic pagination,
  malformed/missing IDs, anonymous deletion, repeated reversion, cleanup
  return values, worker batches, and OpenSearch deletion.

## Findings

- `delete_loaded_tag_change/2` has a FIXME asking to fix a crash; member delete
  authorizes a possibly absent load and manually translates errors.
- `delete_empty_tag_changes/0` has a TODO questioning whether its query works
  because it appears to lack the expected select.
- `load/3` has a TODO questioning redundant resource filters; `resource_filter`
  also uses direct moderator/admin role matching for IP/fingerprint access.
- Raw change creation/deletion, reindexing, batch revert, and controller listing
  are all public and interleaved with private mechanics.

## Work

- Replace member deletion with shared safe loading followed by action-specific
  authorization and a transaction-safe delete/reindex path. Determine the crash
  from characterization and handle its concrete missing association/job/error
  case rather than rescuing broadly.
- Rewrite `delete_empty_tag_changes/0` as one explicit delete query returning the
  affected IDs needed for indexing, and test the SQL result shape. Remove it if
  no caller/invariant requires cleanup.
- Let the query language own resource filtering where equivalent. Remove legacy
  `resource_type/resource_id` params after controller compatibility review, or
  translate them once into query syntax. Gate IP/fingerprint queries with
  Authorization, not role strings.
- Classify raw create/delete/reindex/batch functions as private or documented
  worker/service APIs. Reorder private query/revert/index mechanics before public
  list/revert services and document partial/batch failure behavior.

## TODO/FIXME resolution

- Reproduce and fix the delete crash.
- Correct or delete the empty-change cleanup query.
- Remove redundant resource filtering after proving query-language parity.

## Verification

- Cover malformed/missing/forbidden change IDs, each revert scope, concurrent or
  already-reverted changes, sensitive resource filters, cleanup SQL results,
  worker batches, and OpenSearch updates.
