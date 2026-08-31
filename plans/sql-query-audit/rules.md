# Rules SQL shape audit

Refs: master -> context-logic
Status: complete
Query sites inspected: 11 logical operation families across both refs

## Changed shapes

no SQL shape changes found.

The branch changes the public context API, authorization sequencing, and
error handling, but each database relation has the same base table, predicates,
ordering, and write target as its master counterpart. The old controller-side
position loader and permission check are consolidated in `Rules.load_authorized_rule/3`;
authorization is still applied to the loaded `%Rule{}` in memory rather than
added as a SQL visibility predicate.

## Unchanged or non-index-relevant sites

- `list_rules/0` (`master:lib/philomena/rules.ex:22-24`; current private helper
  `lib/philomena/rules.ex:23-25`) selects all `rules` rows and orders by
  `position ASC`. The helper is now selected by `list_rules_for/1` for an actor
  authorized to edit rules; the relation is unchanged.
- `list_visible_rules/0` (`master:lib/philomena/rules.ex:34-40`; current
  `lib/philomena/rules.ex:27-33`) selects `rules` with fixed predicates
  `hidden = false AND internal = false`, ordered by `position ASC`. It is the
  non-edit branch of `list_rules_for/1`; no predicate or ordering changed.
- `list_reportable_rules/0` (`master:lib/philomena/rules.ex:51-57`; current
  `lib/philomena/rules.ex:45-51`) selects `rules` with `internal = false`,
  ordered by `position ASC`. The query moved from a public view consumer into
  the context and is now reused by report form construction and the legacy
  converter, but its SQL shape is unchanged.
- The `find_rule/1` caller in `master:lib/philomena/reports.ex:92-98` is paired
  with `Rules.fetch_rule/1` and `Loader.fetch/3` at current
  `lib/philomena/rules.ex:65-68`: both are a `rules` primary-key member lookup
  (`id = :id`). ID parsing can avoid issuing SQL for malformed values, but does
  not change the SQL shape for valid IDs.
- `get_by_name!/1` at `master:lib/philomena/rules.ex:103` is paired with
  `fetch_rule_by_name/1` at current `lib/philomena/rules.ex:82-87`: both are a
  `rules` member lookup with `name = :name` and a one-row limit. The current
  `Loader.one/1` changes the return contract, not the access path.
- The position lookup used by the master resource plug and explicit
  `check_permission/2` (`master:lib/philomena_web/controllers/rule_controller.ex:8-13,49-60,63-80,143-159`)
  is paired with `load_authorized_rule/3` and `Loader.one_and_authorize/3` at
  current `lib/philomena/rules.ex:161-166`. Both issue a `rules` member lookup
  with `position = :position` and a one-row limit. The current path parses the
  integer before querying and authorizes after loading; it does not add
  `hidden` or `internal` to SQL. The old show path could perform the same
  position lookup again in `check_permission/2`; eliminating that duplicate is
  a query-count change, not a query-shape change.
- `list_rule_versions/1` (`master:lib/philomena/rules.ex:114-121`; current
  `lib/philomena/rules.ex:98-106`) is identical: base table `rule_versions`,
  fixed equality `rule_id = :rule_id`, `ORDER BY created_at DESC, id DESC`,
  followed by the `user` association preload. The secondary preload is a
  standard `users` primary-key `IN` lookup in both refs. The deterministic
  `id DESC` tie-breaker is present in master as well as context-logic.
- Rule/version creation and update paths retain the same write row-selection
  behavior. Rule and initial/version-history rows are inserted at master
  `lib/philomena/rules.ex:123-134` and current `lib/philomena/rules.ex:108-130`;
  rule updates remain changeset updates by the loaded `rules.id` at master
  `lib/philomena/rules.ex:137-153` and current `lib/philomena/rules.ex:141-153`.
  The renamed/private helpers and authorization gates do not alter an
  `UPDATE`/`DELETE` predicate or an upsert conflict target.
- `Rule` and `RuleVersion` schemas are unchanged apart from type declarations
  (`master:lib/philomena/rules/rule.ex`, `master:lib/philomena/rules/rule_version.ex`;
  current counterparts). `RuleVersion.belongs_to :user` has no association
  `where` clause. `Report.belongs_to :rule` is likewise unchanged and has no
  association visibility predicate; report-side `preload(:rule)` calls are
  standard Rule primary-key preloads, not new Rules-owned query shapes.
- The report view's `report_categories/0` query at
  `master:lib/philomena_web/views/report_view.ex:16-19` moved to the context
  callers (`current:lib/philomena/reports.ex:350-364,392-400,424-430` and
  `lib/philomena/reports/legacy_converter.ex:39-47`), which consume
  `Rules.list_reportable_rules/0`. The moved workload is paired with the
  unchanged reportable-rule relation above.

Index status for the unchanged relations: `rules_pkey` covers ID lookups;
`rules_name_index` uniquely covers name lookups; and `rules_position_index`
covers position lookups and supplies the collection ordering. The visibility
and reportable predicates are residual filters on the position-ordered scan;
no branch change justifies a new composite or partial index.

## New, deleted, moved, or ambiguous sites

- `list_rules/0`, `list_visible_rules/0`, `change_rule/2`,
  `create_rule_with_version/2`, and `update_rule_with_version/3` became private
  implementation helpers behind actor-aware context APIs. They are moved or
  renamed counterparts, not new SQL workloads.
- The old `RuleController` resource plug and `check_permission/2` were removed;
  `list_rules_for/1`, `show_rule/2`, `new_rule/1`, `create_rule/2`,
  `edit_rule/2`, and `update_rule/3` now own the same rule queries. Their
  authorization and malformed/missing-ID behavior changed, but no SQL shape
  changed.
- `Rules.find_rule/1` and `Rules.get_by_name!/1` were deleted as public APIs.
  Their report creation/system-report callers are paired with
  `fetch_rule/1` and `fetch_rule_by_name/1` above. The current legacy converter
  is split into `Philomena.Reports.LegacyConverter`, but its reportable-rule
  list and report preload have the same relational shapes.
- No Rules-owned `exists?`, aggregate, stream, `delete_all`, `update_all`,
  locking query, worker query, or schema association `where` clause was found
  beyond the sites listed above. No ambiguous counterpart remains.

## Follow-ups

- `rule_versions` has no secondary index on `rule_id` or on the history order;
  the structure dump contains only `rule_versions_pkey` for that table and the
  `rule_versions_rule_id_fkey` constraint. A baseline performance review could
  evaluate `(rule_id, created_at DESC, id DESC)`, but it is not a
  context-logic shape delta and should not be proposed as a branch index
  change without representative `EXPLAIN (FORMAT JSON)`, table/cardinality,
  and workload evidence.
- The Rules index coverage is unchanged at both refs. The originating
  migration `priv/repo/migrations/20251103173014_create_rules.exs:19-20` creates
  only the unique `rules(name)` and `rules(position)` indexes; the migration
  history between the refs adds no Rules or RuleVersion index. Current
  `priv/repo/structure.sql:3014-3026,4710-4720,5836-5848` confirms the primary,
  unique, and foreign-key definitions; the corresponding master structure
  sections are identical.
- `Loader` and authorization are shared helpers and should be canonically
  linked from `shared.md`; this report treats their Rules uses as unchanged
  member lookups. No representative EXPLAIN was run because no changed SQL
  shape or unsupported index recommendation required one.
- No application code, migration, schema, test, or other report was changed by
  this audit.
