# TagChanges context plan

Source: `lib/philomena/tag_changes.ex`; consumers: change list and single/full
revert controllers, workers, indexing, and user erasure.

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
