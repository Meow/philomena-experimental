# Interactions SQL shape audit

Refs: master -> context-logic  
Status: complete

Query sites inspected: `lib/philomena/interactions.ex`, the interaction
association definitions in `lib/philomena/images/image.ex`, the moved merge
call in `lib/philomena/images.ex`, and the delegated transaction helpers in
`lib/philomena/image_hides.ex`, `lib/philomena/image_faves.ex`, and
`lib/philomena/image_votes.ex`. Callers in the image, gallery, search, tag,
activity, profile, and API controllers were checked in both refs. The
interaction behavior is covered by `test/philomena/image_interactions_test.exs`.

--- files ---

- `plans/sql-query-shape-audit.md`
- `lib/philomena/interactions.ex`
- `lib/philomena/images.ex`
- `lib/philomena/images/image.ex`
- `lib/philomena/image_hides.ex`
- `lib/philomena/image_faves.ex`
- `lib/philomena/image_votes.ex`
- `lib/philomena/image_hides/image_hide.ex`
- `lib/philomena/image_faves/image_fave.ex`
- `lib/philomena/image_votes/image_vote.ex`
- `test/philomena/image_interactions_test.exs`
- `priv/repo/structure.sql`
- interaction-related migration history under `priv/repo/migrations/`

## Changed shapes

### `migrate_interactions` -> `migrate_loaded_images` merge transaction

- Master: `lib/philomena/interactions.ex:migrate_interactions/2` (called by
  `lib/philomena/images.ex` in the merge workflow). It first issued four
  association preloads from the source image, then four `INSERT ...
ON CONFLICT DO NOTHING` operations into `image_hides`, `image_faves`, and
  `image_votes` (votes split by fixed `up = true`/`up = false` source lists),
  followed by `UPDATE images SET ... WHERE id = $target_id`.
- context-logic: `lib/philomena/interactions.ex:migrate_loaded_images/3`
  runs the source preloads as `source_interactions/2`, then composes
  `ImageHides.put_migrate_image_interactions/2`,
  `ImageFaves.put_migrate_image_interactions/2`, and two
  `ImageVotes.put_migrate_image_interactions/4` steps, followed by
  `Images.put_image_counter_deltas/4`.
- Delta: ownership and `Ecto.Multi` composition changed. The source preload
  relation is the same (four association preload families, with the vote
  preloads carrying the schema `up` predicates). Each insert retains the same
  target `image_id`/source `user_id` row values and `ON CONFLICT DO NOTHING`.
  Fave/vote inserts now add `RETURNING user_id`; this changes returned data,
  not row selection or index access. The image counter update remains an
  `UPDATE images ... WHERE images.id = target_id`; it is now in a shared
  `Multi.run` helper and adds an on-commit reindex callback. No changed lookup
  predicate, join, ordering, grouping, or pagination access path.
- Index status: no index action.
- Evidence: `images.id` is the primary key. Each interaction table has the
  existing unique B-tree `(image_id, user_id)`, which covers the conflict
  checks and target/source pair lookups; each also has a B-tree on `user_id`.
  The current and master `structure.sql` interaction indexes are equivalent.
  `ON CONFLICT` uses the existing unique constraints; no new conflict target
  was introduced. Workload/cardinality evidence was not needed because the
  access requirements did not change.
- Confidence: high

### `user_interactions` argument/empty-input refactor

- Master: `lib/philomena/interactions.ex:user_interactions/2` builds four
  projections and combines them with `UNION ALL`: `image_hides` filtered by
  `image_id IN ids AND user_id = actor`, `image_faves` with the same filters,
  and `image_votes` with the same filters plus `up = true` or `up = false`.
- context-logic: `lib/philomena/interactions.ex:user_interactions/2` (actor
  is now the first argument) builds the same four projections and equivalent
  left-associated `UNION ALL`; `interactions_for_user/2` returns before
  `Repo.all` when `ids` is empty. Anonymous actors likewise still return
  without querying.
- Delta: API argument order and input flattening support changed; the final
  non-empty SQL shape is unchanged. The empty-ID branch is a newly avoided
  query execution, not a changed PostgreSQL access requirement.
- Index status: no index action.
- Evidence: unique `(image_id, user_id)` indexes cover the image/user
  predicates for all four branches; the `user_id` indexes cover the separate
  user-oriented workloads. No branch adds ordering, aggregate, join, or
  visibility predicates.
- Confidence: high

## Unchanged or non-index-relevant sites

- `source_interactions/2` versus the master preload in
  `migrate_interactions/2`: `Repo.preload` versus the transaction repo and
  `force: true` can affect whether already-loaded associations are refreshed,
  but the generated association SQL has the same base tables, foreign-key
  predicates, and `up` association predicates. The preload families are:
  `image_hides.image_id`, `image_faves.image_id`, and
  `image_votes.image_id` with `up = true/false`, followed by user ID joins.
- The four `user_interactions` branches are called from multiple moved or
  newly assembled pages (image, search/reverse, tag, activity, profile, and
  gallery flows). Those call-site moves do not alter the query shape and are
  owned here as the canonical finding; consumers should link to this report.
- Counter updates composed through `Images.put_image_counter_delta(s)` retain
  primary-key selection on `images.id`; changed counter fields and callbacks
  do not alter row selection.

## New, deleted, moved, or ambiguous sites

- The master `migrate_interactions/2` operation is replaced by
  `migrate_loaded_images/3`; it is a moved/split operation, not a deleted
  workload. The new helpers in `ImageHides`, `ImageFaves`, and `ImageVotes`
  are the persistence-owner implementations of its former insert steps.
- Master callers passed `(images, user)`; current callers pass
  `(actor, images)`. This is an API/authorization migration. Anonymous actor
  behavior remains a no-query branch.
- Gallery interaction deletion/migration queries removed from the old
  `Images` implementation belong to the `Galleries` context and are outside
  this report; they are not SQL issued by `Philomena.Interactions`.
- No ambiguous Interactions-owned SQL site was found. No `Repo.aggregate`,
  `Repo.exists?`, `Repo.stream`, or interaction-owned ordered collection query
  exists in either ref.

## Follow-ups

- Link shared/cross-context synthesis to this report for the canonical
  `user_interactions` UNION and image interaction preload finding.
- No index candidate is proposed. A `(user_id, image_id)` index could be
  considered only for a separately demonstrated high-volume per-user UNION
  workload, but the existing `user_id` index plus unchanged
  `(image_id, user_id)` unique indexes provide coverage and there is no plan or
  cardinality evidence warranting additional write cost.
- The current `user_interactions` function uses `Actor` pattern matching and
  therefore changes the public API contract; this is correctness/API scope,
  not an index concern.
