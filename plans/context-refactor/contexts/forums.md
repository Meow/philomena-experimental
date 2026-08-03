# Forums context plan

Source: `lib/philomena/forums.ex`; consumers: HTML/API forum listing/show, admin
forum CRUD, and subscription controllers.

## Findings

- `load_forum/2` and `fetch_forum/1` split one load operation; a TODO suggests
  folding them together.
- `load_forum_index/1` counts all topics rather than actor-visible topics.
- Legacy `list_public_forums/1` and `load_public_forum/1` bypass actor scoping;
  TODO/FIXME comments call for their deletion and note that a controller wrongly
  depends on the latter.
- `authorize_admin/1` is public context-specific role gating; admin CRUD does not
  use distinct actions.

## Work

- Build one safe slug query loader and authorize the real forum for `:show` or
  requested mutation. Fold `fetch_forum` into it and give malformed/unknown slugs
  a single not-found result.
- Delete public bypass list/show functions. Migrate HTML and JSON controllers to
  actor-scoped loaders, passing an anonymous Actor for public requests.
- Count topics through the same visibility predicate used by Topics; avoid
  leaking hidden/restricted topic counts. Add a documented page result if list
  assembly grows beyond a simple list.
- Replace `authorize_admin/1` with normal class/instance actions for new/create/
  edit/update. Keep subscription actions actor-scoped and explicit.
- Make raw create/query/subscription helpers private where possible, reorder the
  module, and document restrictions, counts, and notification effects.

## TODO resolution

- Fold the duplicate loader, actor-scope topic counts, delete both legacy public
  APIs, and remove the controller dependency on `load_public_forum/1`.

## Verification

- Test anonymous/user/staff views of restricted forums and topic counts,
  malformed/unknown slugs, API parity, subscription permissions, and each admin
  CRUD action.
