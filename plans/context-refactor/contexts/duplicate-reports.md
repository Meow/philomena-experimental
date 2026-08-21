# DuplicateReports context plan

Source: `lib/philomena/duplicate_reports.ex`; consumers: duplicate reporting,
search/reverse-search, and accept/claim/reject controllers.

## Implementation status

Complete for wave 4.

- Actor-first, action-specific APIs now own the staff index, public show,
  duplicate form/submission, reverse search, transitions, and navigation count.
  One private loader normalizes report IDs before authorization, while both
  report images must be visible to the actor. Public viewers see existing
  reports only when both images remain visible; duplicate-report staff retain
  their explicit hidden-image visibility.
- Form preparation and submission share write-access and `:create` checks.
  Source and target locators are separate from attrs and load through Images'
  actor-visible report-target API; rejected input returns the associated
  changeset instead of bespoke report-failure tuples.
- Accept and reverse-accept lock every report for the image pair and both images
  in stable order, revalidate direction and permissions inside the transaction,
  reject competing active reports, and compose the image merge and moderation
  log atomically. Image indexing, notifications, thumbnails, and firehose work
  remain after-commit effects.
- Claim, unclaim, accept, and reject changesets enforce active states. Claims
  are row-locked, so repeated or concurrent claims return validation errors and
  cannot reassign the reviewer or duplicate the audit log.
- Reverse search returns a typed `SearchResult`, preserves validation failures,
  deterministically orders equal matches, and filters hidden images for actors
  who cannot view them. Perceptual query construction, raw insertion, upload
  analysis, and transition mechanics are private; automated generation remains
  a documented media-pipeline service.
- Context and controller coverage now includes normalized report/image IDs,
  forbidden and hidden resources, form/write parity, state failures, reverse
  direction, competing reports, concurrent claims, atomic logs/merges, search
  validation, and reverse-search visibility.

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
