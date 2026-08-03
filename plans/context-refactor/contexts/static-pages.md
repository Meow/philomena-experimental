# StaticPages context plan

Source: `lib/philomena/static_pages.ex`; consumers: page show/admin CRUD and page
history controllers.

## Findings

- `get_static_page!/1` and raw create/update functions remain public above the
  actor-scoped API.
- Slug loading is a custom `Repo.get_by` plus authorize/absence sequence. History
  loading is public without Actor even though page visibility may matter.
- `update_page/3` has a TODO asking whether to return the page rather than the
  entire Multi result map.
- The private loader is at the end; several docs describe role-dependent missing
  behavior that should disappear.

## Work

- Add shared query-based slug loading and authorize only a real page. Make show,
  history, edit, and update actor-first; history must not bypass visibility.
- Apply action-specific collection/member permissions and
  `verify_write_access/1` to form/write administration as appropriate.
- Make raw bang/CRUD/version helpers private. Return `{:ok, static_page}` from
  create/update, preserving changesets on validation error; keep the transaction
  map internal.
- Move private CRUD/version/query/load functions before public APIs and document
  slug uniqueness, version creation, missing/forbidden behavior, and transaction
  results.

## TODO resolution

- Return the updated page, not an Ecto.Multi implementation detail.

## Verification

- Cover anonymous visibility, malformed/unknown/forbidden slugs, history access,
  form/write parity, validation, version rollback, and per-action admin rules.
