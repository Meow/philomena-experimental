# Reports context plan

## Status

Wave 2 complete. Report forms and submissions now share the tagged locator API
`new_report/2` and `create_report/3`, returning a typed `ReportForm` that retains
the safely loaded target on validation failure. Comments and Posts expose only
parent-scoped target locators; report changeset construction is private to
Reports.

Report IDs load before authorization, staff transitions use distinct
`:claim`/`:unclaim`/`:close` abilities under a row lock, and transition updates
commit with their moderation logs. Repeated unclaim/close operations are
idempotent, while repeated or racing claims cannot reassign a claimed report.
The direct CRUD and preload surface is gone; bulk-close composition,
after-commit indexing, worker indexing, conversion, system reports, and rename
index updates remain documented service APIs.

Source: `lib/philomena/reports.ex`; consumers: report index/show/create plus
claim/close controllers and report loaders delegated to Images, Galleries,
Users, Commissions, Conversations, Posts, and Comments.

## Findings

- `load_report/2` reproduces parse/load/auth logic with actor-dependent absence.
  Each reportable type has separate display and creation loaders, with form paths
  using `verify_not_banned/1` and creation paths `verify_write_access/1`.
- Gallery/user/conversation loaders authorize a possibly `nil` subject and use
  custom `else`; reportable visibility logic is duplicated across contexts.
- `change_report/1` is public because Comments/Posts build report forms. Its
  FIXME says those functions belong here and `change_report` should be private.
- Raw CRUD, system reports, close queries, indexing, conversion, and controller
  APIs form a very broad mixed public surface. Some direct `Canada.Can.can?`
  checks gate listing/mod-note data.

## Work

- Replace report ID loading with shared Loader and distinct show/edit/claim/
  unclaim/close actions. Missing IDs are always not-found; all transition checks
  happen on a real report.
- Create one typed report-form API owned here for each reportable locator (or one
  tagged locator type). It should safely load the target through its owning
  actor-scoped context, authorize reportability, and return the report changeset
  plus target. Move Comments/Posts report changeset construction into Reports
  and make `change_report/1` private.
- Require `verify_write_access/1` for report forms and creation, deleting the
  weaker duplicate loaders unless a read-only preview is genuinely needed.
- Replace direct Canada checks with `authorize/3`. Ensure sensitive mod notes,
  open-report throttling, and user/IP limits run only after the appropriate gate.
- Make raw CRUD/close query/preload/conversion/index mechanics private or a
  separately documented maintenance/worker API. Compose report transitions and
  ModerationLogs in one transaction.
- Reorder private target loading, queries, CRUD, and indexing before public
  controller/service APIs. Document target visibility, throttling, anonymity,
  transition races, and indexing.

## TODO/FIXME resolution

- Privatize `change_report/1` and move all comment/post report-form assembly into
  Reports.

## Verification

- Build a cross-target matrix for malformed/missing/hidden/forbidden targets and
  form/create parity. Test report ID outcomes, open-report limits, sensitive
  notes, claim races, close idempotency, system reports, transaction/logging, and
  OpenSearch updates.
