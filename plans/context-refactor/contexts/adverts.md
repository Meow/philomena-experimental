# Adverts context plan

Source: `lib/philomena/adverts.ex`; consumers: public advert selection/recording
and the advert/admin image controllers.

## Findings

- Administrative APIs (`new_advert`, create, load/edit, update, delete, and
  image update) all authorize `:index` instead of their actual action.
- `get_advert/1`, raw impression/click recording, and public selection sit beside
  controller orchestration; classify which are service APIs and hide the rest.
- `update_advert_image/3` contains a TODO proposing reuse of the ordinary update
  path, but its moderation-log contents and upload side effects differ.
- Private loaders/log helpers are interleaved with documented APIs.

## Work

- Make every admin function actor-first and action-specific (`:new`, `:create`,
  `:edit`, `:update`, `:delete`). Use the shared loader for all ID member paths
  and return not-found before authorization only after a real lookup.
- Keep `random_live/1`, impression recording, and click recording as explicitly
  documented public-service APIs because they are not admin controller actions;
  validate advert IDs without raising and state their no-authorization rationale.
- Make `get_advert/1`, raw create/update helpers, upload plumbing, and moderation
  log construction private unless a concrete non-context caller requires a
  narrow replacement.
- Resolve the image-update TODO by extracting one private transaction builder
  shared with ordinary update while preserving an explicit image-change log.
  Ensure file persistence and database/log changes have a documented failure
  boundary.
- Reorder private CRUD/query/log/upload functions before the public API and
  replace the placeholder moduledoc.

## Verification

- Add a per-action admin/moderator/user matrix, malformed/missing ID cases, and
  advert image upload failure coverage to `adverts_test.exs` and both admin
  advert controller test files.
- Assert impression/click requests cannot mutate an absent or non-live advert in
  an unintended way.
