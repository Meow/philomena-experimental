# Versions context plan

Source: `lib/philomena/versions.ex`; consumers: post/comment history and edit
transactions.

## Findings

- Public post/comment version loaders accept loaded parents with no actor, while
  controller authorization is expected to happen in Posts/Comments. That
  assumption is not documented and could become a bypass.
- `record_edit/…` is a public service used by aggregate transactions, but its
  attribution/version invariants and return shape are undocumented.
- Public functions and private generic helpers are interleaved, and the module
  has few specs/docs relative to its service role.

## Work

- Make history controller APIs live in Posts/Comments after those contexts load
  and authorize the parent. Keep Versions' parent-based load function private or
  a clearly internal service that cannot accept request IDs.
- Keep `record_edit` as a Multi-compatible documented service accepting an
  authorized loaded parent and Actor attribution; define when no version is
  created and how concurrent edits order versions.
- Put private schema/fk query and changeset mechanics first, then the minimum
  service surface. Add specs and examples for post and comment edits.
- Resolve `Versions.LegacyBackfill`'s release-number TODO: verify deployed schema
  state and release support policy, delete the module/release entry point/tests
  when the legacy table can no longer exist, or replace the version guess with a
  concrete checked removal condition.

## Verification

- Test parent authorization through Posts/Comments, ordering, attribution,
  no-op edits, transaction rollback, concurrent version numbers, and safe legacy
  backfill removal.
