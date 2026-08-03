# Rules context plan

Source: `lib/philomena/rules.ex`; consumers: rule list/show/new/edit/update
controller and report rule selection.

## Status

The controller boundary is implemented as a wave 1 position-loader exemplar.
Hidden/internal visibility now lives in Ability, position loading uses
`Loader.one_and_authorize/3`, absent positions are uniformly not-found, write
forms and mutations share the write prerequisite, and raw version mutations are
private. Report-facing rule lookup/list services remain public until the Reports
wave can move report form assembly behind an actor-scoped boundary.

## Findings

- Visibility uses direct `Canada.Can.can?` calls, while other operations use
  Authorization. Hidden/internal rule handling is therefore its own permission
  path.
- Position is the route locator; `load_authorized_rule/3` safely parses but
  manually translates parse/load/auth errors. `get_by_name!/1` remains a public
  bang loader.
- Low-level versioned create/update and list/query helpers are public beside the
  controller API, and admin operations need action-specific review.

## Work

- Express hidden/internal visibility and reportability as abilities and use
  `authorize/3` exclusively. Authorize collection list variants explicitly.
- Add a query-based Loader path for integer positions; fetch a real rule then
  authorize. Remove actor-dependent/custom error translation and keep name bang
  lookup only as a clearly internal invariant API, preferably private/safe.
- Apply `verify_write_access/1` to rule write form/mutation paths if the global
  prerequisite applies. Distinguish new/create/edit/update actions.
- Make versioned insert/update transaction builders and raw queries private.
  Keep a documented reportable-rules service only if Reports calls it with an
  actor.
- Reorder private lookup/version transaction mechanics first and document
  position renumbering, hidden/internal behavior, and version creation.

## Verification

- Cover malformed/missing positions, hidden/internal rules for all actor levels,
  reportable lists, form/write parity, version rollback, and position changes.
