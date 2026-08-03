# ModNotes context plan

Source: `lib/philomena/mod_notes.ex`; consumers: admin mod-note controller and
several contexts that render notes for a target.

## Findings

- Multiple list functions accept column/ID tuples or renderers, exposing query
  mechanics to callers and making target authorization unclear.
- `get_mod_note!/1`, raw update/delete overloads, and `change_mod_note/1` are
  public alongside actor-scoped operations.
- New/create/member operations have authorization, but action choice and safe ID
  loading should be unified; target IDs parsed from params are handled locally.
- Moderation notes contain sensitive data, so authorizing only the top-level list
  while allowing arbitrary target selectors needs explicit review.

## Work

- Define a typed target descriptor (schema/type plus safe locator) inside the
  context; remove raw column names and collection renderer concerns from the
  persistence API.
- Authorize both `:index`/CRUD and access to the selected target's sensitive
  details. Safely parse target/member IDs with the shared loader and return a
  stable not-found/unauthorized contract.
- Remove `get_mod_note!` from request paths; make raw update/delete/change/query
  functions private. If Profiles/Reports/DNP need notes, expose one documented
  actor-scoped `list_for_target/3` service.
- Reorder private target/query/CRUD/log functions before controller/service APIs.
  Document target support, sensitivity, pagination, and moderation logging.

## Verification

- Test every supported target kind, malformed/missing target and note IDs,
  permission distinctions, query-string filters, CRUD logs, and calls from
  Profiles/Reports/DnpEntries.
