# Badges SQL shape audit

Refs: master -> context-logic
Status: complete

--- status ---

Audited the Badges context and nested Badge/Award/Uploader modules, the moved
admin badge and profile-award callers, the deleted Artist-link awarder, award
association preloads, and the relevant schema/index history. No application
code, migration, test, or schema files were changed.

Query sites inspected: 13 distinct executed SQL shape families, including
pagination count/page companions and award association preloads, plus the
deleted legacy query definitions and moved callers.

## Changed shapes

### Profile target lookup adds active-user filtering

- Master: `lib/philomena_web/controllers/profile/award_controller.ex:12`,
  `load_resource` for `User` with `id_field: "slug"`; the lookup is by the
  unique `users.slug` column.
- context-logic: `lib/philomena/badges.ex:285-290`,
  `load_authorized_profile/3`; `users WHERE slug = $1 AND deleted_at IS NULL`,
  followed by authorization. This helper is used by new/create/edit/update/
  delete award operations.
- Delta: added the fixed `deleted_at IS NULL` predicate to the slug member
  lookup.
- Index status: covered
- Evidence: both structure dumps contain unique B-tree
  `index_users_on_slug (slug)`. It makes the slug lookup selective; the null
  test is a residual predicate. No additional Badges index migration exists.
- Confidence: high

### Award member lookup becomes profile-scoped

- Master: `lib/philomena_web/controllers/profile/award_controller.ex:13`,
  `load_resource` for `Award`; the member lookup is keyed by
  `badge_awards.id`, while the profile user is loaded independently.
- context-logic: `lib/philomena/badges.ex:292-298`,
  `load_scoped_award/4`; `Award |> where(user_id: ^user.id) |> preload([:user,
:badge]) |> Loader.fetch_and_authorize(...)`. The final member SQL is
  effectively `badge_awards WHERE user_id = $1 AND id = $2`, followed by
  primary-key preloads for `users` and `badges`.
- Delta: added the parent `user_id` predicate and added `user`/`badge`
  preloads. The subsequent UPDATE/DELETE operations still target the loaded
  row by its primary key, so their write predicates are unchanged.
- Index status: covered
- Evidence: `badge_awards_pkey (id)` covers the member lookup,
  `index_badge_awards_on_user_id (user_id)` covers the added scope, and the
  `users_pkey`/`badges_pkey` indexes cover the preloads. All are present in
  both structure dumps; no migration changes them.
- Confidence: high

### Artist badge award reads move into the Badges transaction builder

- Master: `lib/philomena/artist_links/badge_awarder.ex:19-22`,
  `award_badge/2`, calls `Badges.get_badge_by_title("Artist")`, then
  `Badges.get_badge_award_for/2`: equality lookup on `badges.title`, followed
  by `badge_awards.badge_id = $1 AND user_id = $2`, then a conditional insert.
- context-logic: `lib/philomena/badges.ex:528-543`,
  `put_award_artist_badge/3`, performs the same two reads through the
  transaction repo and conditionally inserts the award. It is called by
  `lib/philomena/artist_links.ex:347-366`.
- Delta: module/API and transaction-repo ownership changed; the relational
  read and insert shapes did not change.
- Index status: no index action
- Evidence: separate B-tree indexes on `badge_awards.badge_id` and
  `badge_awards.user_id` exist in both refs. There is no title index, but the
  fixed Artist title is a singleton administrative/verification lookup and
  this diff provides no workload or plan evidence for adding one.
- Confidence: high

## Unchanged or non-index-relevant sites

- `Badges.list_badges/2` (`lib/philomena/badges.ex:41-47`) is the moved admin
  collection from `lib/philomena_web/controllers/admin/badge_controller.ex:12-18`:
  `badges ORDER BY title ASC` with pagination and its count companion. Same
  relational shape; the small administrative collection does not justify a
  title-order index.
- `Badges.list_badge_users/3` (`lib/philomena/badges.ex:265-275`) is the exact
  moved query from `lib/philomena_web/controllers/admin/badge/user_controller.ex:12-22`:
  `users INNER JOIN badge_awards ON badge_awards.user_id = users.id`, filter
  `badge_awards.badge_id = $1`, order `users.name ASC`, with pagination/count.
  The `badge_id`, `user_id`, `users.id`, and unique `users.name` indexes cover
  the lookup/join/order alternatives. No shape change or index recommendation
  follows. The order has no tie-breaker, unchanged from master.
- `Badges.awardable_badges/0` (`lib/philomena/badges.ex:278-283`) is the moved
  `load_badges/2` query from `lib/philomena_web/controllers/profile/award_controller.ex:74-81`:
  `badges WHERE disable_award = false ORDER BY title ASC`. It is reused for
  award form error branches; same collection shape and no index action.
- `Badges.load_badge/3` (`lib/philomena/badges.ex:22-24`) delegates to the
  shared primary-key loader for admin badge edit, image edit, and badge-user
  listing. It replaces the old resource loader without changing the badge-id
  member lookup shape.
- Badge create/update/image-update changesets and the corresponding
  `Multi.insert`, `Multi.update`, and `Multi.delete` operations do not alter
  row-selection predicates. Moderation-log and upload callbacks add no
  Badges access path requiring an index.
- `lib/philomena/badges/award.ex`, `badge.ex`, and `uploader.ex` contain no
  query-shape changes. Their changes are types, changeset defaults, and upload
  callback composition.
- Award association preloads remain the standard child lookup by
  `badge_awards.user_id` followed by `badges.id`; the `has_many :awards`
  association in `lib/philomena/users/user.ex:35` has no `where` clause. The
  current preload consumers include `profiles.ex`, `users.ex`, `images.ex`,
  `posts.ex`, `comments.ex`, `versions.ex`, and commissions; their relevant
  award preload shapes are unchanged by this context refactor.
- The create-award moderation-log callback's `Repo.preload(award, :badge)` at
  `lib/philomena/badges.ex:365` is a primary-key badge preload corresponding
  to the old controller log helper; no index action.

## New, deleted, moved, or ambiguous sites

- `Philomena.ArtistLinks.BadgeAwarder` is deleted and replaced by
  `Badges.put_award_artist_badge/3`. This is a moved workload, paired above,
  not a new SQL shape.
- The old controller-local badge listing, badge-user listing, awardable-badge
  listing, and resource loads are deleted from `lib/philomena_web` and
  recreated in `Philomena.Badges`; their counterparts are classified above.
- The old public `Badges.get_badge!` and `get_badge_award!` definitions had no
  callers in either the application or tests searched on master. Their
  deletion removes unused primary-key query definitions, not an active
  workload. Likewise, old `list_badge_awards/0` had no caller found.
- `Loader.fetch_and_authorize/5` and `Loader.one_and_authorize/3` are shared
  query/authorization helpers. They are reviewed here only as used by Badges;
  canonical cross-context findings belong in `shared.md`.
- No ambiguous Badges-owned SQL site was found. OpenSearch requests and badge
  serialization were excluded from this SQL audit.

## Follow-ups

- Correctness/stability: `list_badge_users/3` orders only by `users.name ASC`.
  Equal names can make page boundaries unstable. This is unchanged from
  master and is not an index recommendation; a future `name, id` tie-breaker
  would need a separate access-path review.
- Correctness/concurrency: automatic Artist awarding still uses a read-then-
  insert check for `(badge_id, user_id)` without a unique constraint. Profile
  awards intentionally allow duplicate grants, so no global unique index is
  proposed from this audit; concurrent verification can still race.
- The added `deleted_at IS NULL` predicate intentionally prevents award
  management through deactivated profiles. It is covered by the unique slug
  lookup rather than a separate `deleted_at` index.
- No representative `EXPLAIN` was run; existing primary/foreign-key and
  unique-index coverage is sufficient for the changed shapes, and no missing
  access path is supported by this diff.
