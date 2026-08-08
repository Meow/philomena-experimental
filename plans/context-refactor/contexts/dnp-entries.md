# DnpEntries context plan

## Status

Wave 2 complete. Public, mine, and admin listings retain a typed `DnpListing`;
show pages now return a `DnpEntryPage` containing the authorized entry and
optional moderation notes; and new/edit plus validation failures share a typed
`DnpEntryForm`. Successful writes return the saved entry directly.

Every form and mutation uses the global write prerequisite. DNP abilities now
name admin index, new/create, edit/update, transition, and privileged tag
selection separately. Entries load before instance authorization with their tag
preloaded, while privileged tag IDs use `Loader` and normalize malformed or
missing values to not-found. A moderator edit defaults to the entry's current
tag, and unoffered submitted tags remain changeset errors.

Raw insert and loaded-transition helpers are private. Staff transitions lock the
entry and commit the state update with its moderation log in one transaction;
missing or invalid states are rejected by the schema changeset rather than the
database.

Source: `lib/philomena/dnp_entries.ex`; consumers: public/mine/admin DNP listing,
CRUD, and transition controllers.

## Findings

- Four TODOs question the success shapes of new/create/edit/update. Some return
  tag lists plus changesets or transaction maps with no named contract.
- Form loaders and writes use different write prerequisites. Tag selection uses
  direct `Canada.Can.can?`, and privileged tag lookup uses `Repo.get!` on request
  params.
- Member loading has both required and authorized variants, and list visibility
  is partly encoded through clauses and partly through ability checks.
- Low-level insert/transition functions are public above the controller API.

## Work

- Introduce small result structs (for example `DnpListing` and `DnpForm`) for
  page/form data: entry/changeset, selectable tags, and mod-note capability.
  Return the saved entry rather than an opaque Multi map on successful writes.
- Replace form `verify_not_banned/1` gates with `verify_write_access/1`. Use
  action-specific authorization for admin listing, create, edit, update, and
  transition.
- Move selectable-tag permission into Ability/context authorization. Parse and
  safely load `tag_id`; invalid or unauthorized tag choices become changeset or
  normalized authorization errors, never `Repo.get!` crashes.
- Consolidate required/authorized entry loading on shared Loader primitives with
  consistent `:tag` preload and missing-before-instance-authorization semantics.
- Make raw insert/loaded transition private or a narrowly documented worker
  service. Reorder private query/tag/transition mechanics before public APIs.

## TODO resolution

- Replace all four “weird shape” TODOs with named page/form results and direct
  saved-resource success values.

## Verification

- Test mine/public/admin listings, action-level permissions, malformed entry and
  tag IDs, selectable-tag boundaries, every state transition, changeset
  preservation, and form/write parity.
