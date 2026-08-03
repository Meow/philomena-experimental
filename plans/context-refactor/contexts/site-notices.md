# SiteNotices context plan

Source: `lib/philomena/site_notices.ex`; consumers: public layout notice display
and admin notice CRUD.

## Findings

- This is the closest existing example of the desired API: member CRUD delegates
  to Loader and controller functions are documented. It is a good first migration
  target for the revised shared contract.
- It still authorizes new/create/edit/update/delete with separate wrappers and
  interleaves the private loader after public APIs.
- `active_site_notices/0` is intentionally public/anonymous and needs a clear
  distinction from admin APIs.

## Work

- Migrate first after Loader changes. Verify each class/member action has its own
  ability; add `verify_write_access/1` to admin form and mutation routes if that
  is the global write rule.
- Use the revised Loader so malformed/missing IDs are uniformly not-found and
  forbidden real notices unauthorized without role-dependent behavior.
- Move private query/changeset/loader functions before public APIs. Keep
  `active_site_notices/0` as an explicitly unauthenticated read API and group it
  separately from actor-first administration.
- Rewrite the moduledoc and examples to become the model copied by later small
  contexts, including active-window/timezone and changeset behavior.

## Verification

- Add the canonical Loader matrix here plus active-window boundary and each CRUD
  action. Use the completed code/docs/tests as the reference implementation for
  later context plans.
