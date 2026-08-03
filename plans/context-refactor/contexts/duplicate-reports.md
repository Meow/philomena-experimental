# DuplicateReports context plan

Source: `lib/philomena/duplicate_reports.ex`; consumers: duplicate reporting,
search/reverse-search, and accept/claim/reject controllers.

## Findings

- Show and every transition separately parse IDs, query, authorize, and translate
  errors, producing many near-identical `with ... else` branches.
- Search-query parsing, report generation, image loading, claim transitions, and
  lower-level duplicate-report CRUD are all public.
- Nested source/target image visibility and report permissions are spread across
  custom logic; malformed search/image inputs have bespoke failure shapes.
- There are no explicit TODOs, but this module has one of the highest densities
  of repeated load/authorization branches.

## Work

- Add one private `load_report(actor, action, id)` based on shared Loader and use
  it for show, accept, reverse-accept, claim, unclaim, and reject. Each action
  must authorize its real transition, not a generic edit permission.
- Load both images through actor-visible image APIs and validate report direction
  inside the transition transaction. Existing reports whose images become
  hidden need a documented moderator/user policy.
- Normalize reverse-search/query compilation into a named search result; invalid
  IDs or queries return explicit errors without local catch-all `else` blocks.
- Make raw CRUD, loaded transition steps, and query helpers private. Keep public
  search and worker generation APIs only with distinct docs/specs.
- Reorder private loading/transition/search mechanics before public controller
  APIs and document transaction, merge, reindex, and notification side effects.

## Verification

- Table-test malformed/missing/forbidden report IDs for every transition;
  mismatched/hidden source and target images; concurrency/duplicate claims; and
  search parser failures. Verify database and OpenSearch effects.
