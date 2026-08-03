# UserNameChanges context plan

Source: `lib/philomena/user_name_changes.ex`; current module is an empty context
shell, while the schema/data is consumed through Profiles/Users.

## Findings

- The module contains only `defmodule Philomena.UserNameChanges do end`; it has no
  ownership, docs, or API and therefore cannot satisfy the context convention.
- Keeping an empty top-level context suggests callers should use it even though
  current queries and rename writes live elsewhere.

## Work

- Decide ownership explicitly. Preferred: make this context own private/history
  queries and rename-record insertion as narrow service APIs used by Users and
  Profiles, with actor-scoped sensitive history access at the appropriate edge.
  Alternative: delete the empty module and keep the schema under Users if no
  independent boundary is useful.
- Do not add generic generated CRUD. Expose only record-rename and paginated
  history operations required by the aggregate transaction/page.
- Add a domain moduledoc, specs, unexpected behavior (case-only renames,
  attribution, retention), and examples if retained; follow private-first layout.

## Verification

- Test rename transaction rollback with Users, history ordering/pagination,
  sensitive visibility, and case/duplicate-name behavior.
