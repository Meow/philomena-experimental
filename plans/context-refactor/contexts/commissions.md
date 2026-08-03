# Commissions context plan

Source: `lib/philomena/commissions.ex`; consumers: commission directory/profile
and nested item controllers plus report loading.

## Findings

- Ownership is implemented with custom `load_profile_user`, role checks, and
  `ensure_correct_user/2` rather than the authorization layer.
- New/edit form loaders use `verify_not_banned/1`, while create/update/delete use
  `verify_write_access/1`.
- `load_item_for_edit/3` reaches `Repo.get_by!` through `get_item`, and its TODO
  confirms an invalid item crashes. Parent slug/item membership is therefore not
  represented in the standard result contract.
- Raw commission/item CRUD and search/preload helpers are mixed into the public
  controller surface.

## Work

- Add commission and item abilities that represent owner/staff rules; remove
  direct role checks and the `ensure_*` authorization substitutes.
- Use one actor-scoped profile locator. Load items with a query constrained by
  the commission belonging to the route slug, and return not-found for malformed,
  missing, or wrong-commission IDs.
- Replace every `verify_not_banned/1` form gate with
  `verify_write_access/1`. Specify how a missing/deactivated profile differs from
  a visible profile the actor cannot manage.
- Keep public directory/search and controller orchestration APIs; make raw CRUD,
  preloads, changesets, query compilation, and loaded-record modifiers private
  unless Reports needs a documented cross-context locator.
- Reorder private mechanics before public APIs and document uniqueness (one
  commission per profile), item ordering, indexing, and delete cascades.

## TODO resolution

- Replace the invalid-item raise with safe parent-scoped loading and tests for
  malformed, absent, and mismatched IDs.

## Verification

- Test owner/non-owner/staff and banned/no-fingerprint actors across form and
  mutation paths, one-commission uniqueness, mismatched items, directory search,
  reports, and index updates.
