# Roles context plan

Source: `lib/philomena/roles.ex`; primary aggregate owner: `Philomena.Users`.

## Findings

- This is generic generated CRUD with a public `get_role!/1` and no actor or
  authorization. Controllers reach role data through Users rather than Roles.
- It is unclear whether database roles are independently managed or only used as
  account-assignment/reference data.

## Work

- Inventory callers. If roles are reference data, replace generic CRUD with the
  minimum list/safe lookup service needed by Users and seeds; make mutations
  private or move them into an authorized Users/admin API.
- Remove the public bang lookup from any request path. Safely parse role IDs and
  validate role assignment in the Users changeset/authorization transaction.
- Add a domain moduledoc, specs, and examples for retained service APIs; keep
  private query/changeset functions first.

## Verification

- Test invalid/missing role assignment through Users, protected built-in roles,
  and any uniqueness/deletion constraints.
