# Badges context plan

Source: `lib/philomena/badges.ex`; consumers: badge admin and profile award
controllers.

## Findings

- Most badge administration authorizes only `:index`, including create, edit,
  update, image update, and user listing.
- Award operations use custom profile and award loaders; an award ID must be
  proven to belong to the slug in the route.
- Generic helpers (`get_badge_by_title`, raw award create clauses,
  `awardable_badges`) are public alongside controller APIs, and private
  load/log helpers are interleaved.
- Several public functions lack specs even though their docs suggest different
  success/error shapes.

## Work

- Add/use action-specific abilities for badge and award administration. Apply
  `verify_write_access/1` consistently to form loaders and mutations if these
  routes share the global write prerequisite.
- Replace badge and award lookup with shared Loader primitives. Scope award
  lookup by both profile/user and award ID; return not-found for a mismatched
  nested pair and unauthorized only for an existing correctly scoped record.
- Collapse raw create/update/image/log functions into private transaction steps.
  Retain `get_badge_by_title/1` or award creation as documented service APIs only
  where fixtures/workers have a real need.
- Reorder badge and award private mechanics before a grouped public API. Document
  duplicate awards, image side effects, moderation logs, and revoke behavior.

## Verification

- Cover each authorization action, malformed/missing badge and award IDs,
  mismatched slug/award ownership, duplicate grants, image failure, and revoke
  cleanup in context and controller tests.
