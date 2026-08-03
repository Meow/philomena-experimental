# All-context consistency plan

## Outcome

Give every controller-facing `Philomena` context the same boundary contract:
an actor-first public API, one predictable loading and authorization sequence,
private persistence mechanics, and documentation that states important behavior
without narrating implementation accidents. Resolve every context-layer TODO and
FIXME by implementing it, replacing it with a concrete tracked design decision,
or deleting obsolete code.

This plan intentionally permits stricter behavior. In particular, a GET that
renders a form for a write should enforce the same write-access prerequisite as
the write, nested resources must belong to their URL parent, and legacy public
loaders must not bypass actor visibility.

## Target contract

### Loading and authorization

1. Public controller APIs take `%Philomena.Attribution.Actor{}` first whenever
   the request has an actor. Passing `actor.user` is an internal detail, not a
   second public convention.
2. Mutation endpoints and the `new`/`edit` loaders that prepare them call
   `verify_write_access/1`. Remove `verify_not_banned/1`; it permits a request
   without the fingerprint required by the corresponding write and is the
   source of several documented inconsistencies.
3. Collection/class operations authorize the action before executing the query.
   Use the real action (`:index`, `:new`, `:create`, and so on), not a generic
   `:index` check for all administrative operations.
4. Member operations parse the locator, load a real record, then authorize that
   record for the requested action. The stable result contract is:
   malformed locator or absent/scoped-out row => `{:error, :not_found}`;
   existing but forbidden row => `{:error, :unauthorized}`; failed write-access
   prerequisite => `{:error, :ban}` or `{:error, :unauthorized}`; validation =>
   `{:error, %Ecto.Changeset{}}`.
5. Nested resources are loaded through a query constrained by every parent in
   the route before authorization. Never load a post, comment, poll option,
   commission item, award, or gallery image globally and merely pair it with the
   parent named in the URL.
6. Visibility rules go through `Philomena.Authorization.authorize/3` and the
   Canada abilities. Remove direct role-string checks and scattered
   `Canada.Can.can?/3` calls from context orchestration unless a check is purely
   presentational and has no authorization effect.
7. Public APIs pass normalized errors through unchanged. Prefer linear `with`
   pipelines whose callees already share a result vocabulary; reserve `else`
   for genuine translation from a third-party/parser result, not repeated
   loading/authorization case analysis.
8. Bang loaders are limited to fixture, seed, migration, or invariant-enforced
   internal paths. User-controlled IDs, slugs, positions, poll-option IDs, and
   search/pagination inputs must not raise `Ecto.Query.CastError`,
   `Ecto.NoResultsError`, `ArgumentError`, or `MatchError`.

### Shared implementation

- Change `Loader.fetch_and_authorize/5` to parse, fetch, reject absence, and only
  then authorize. Update its docs and tests so missing IDs no longer produce an
  actor-dependent error.
- Extend `Loader` with the smallest useful query-based primitive (for example,
  `one/1` and `one_and_authorize/3`) so slug, position, composite-key, and
  parent-scoped contexts do not each recreate the same `Repo.one`/`with`/`else`
  machinery. Keep integer parsing in the existing ID helper.
- Add result types for the shared public error vocabulary and use them in
  context specs instead of repeating subtly different unions.
- Delete `Authorization.verify_not_banned/1` after all callers move to the
  stricter prerequisite. Keep `authorize/3` as the sole ability entry point.
- Review the functions injected by `Subscriptions`. Controller operations
  should wrap them with actor-scoped load/authorize functions; raw struct/user
  operations remain internal building blocks and should be `@doc false` only
  where macro-generated cross-context use makes privacy impossible.
- Keep `RateLimiter` separate from authorization. Rate-limit failures are an
  operational write prerequisite and must not be translated into unauthorized
  or not-found results.

### Supporting-marker cleanup

The context audit also found TODO/FIXME markers in supporting modules. Resolve
them in the same waves rather than leaving them outside the per-context count:

- Unify `Philomena.Repo.pagination_params` with the search pagination type and
  make every SQL/OpenSearch loader accept the same validated page contract.
- Remove `Philomena.Schema.TagList` in favor of normalized filter/settings tag
  relations, or replace the marker with a concrete migration issue if schema work
  must land separately. Do not keep denormalized IDs and comma strings as two
  writable sources of truth.
- Remove `Philomena.Versions.LegacyBackfill` at the intended release boundary;
  until then, replace the version-number TODO with an explicit removal condition
  that can be tested from release/schema state.
- Stop using `Philomena.Images.Search.Scope` as an Actor substitute. Carry Actor
  explicitly for authorization and keep filter/query/pagination as search state.
- Move search-query optimization into the parser/query AST; remove Images'
  recursive tag-name pattern matcher once the parser exposes referenced tags.

### Module layout and public surface

Arrange every context in this order:

1. `use`, imports, aliases, module attributes, types, and context configuration;
2. private CRUD, query, transaction, callback, and modifier functions;
3. public controller-facing API, with each function's clauses kept together.

Audit every current `def` before moving it. Convert raw CRUD, loaded-record
modifiers, query builders, callbacks, and preload helpers to `defp` when they are
used only inside the module. If another context, worker, fixture, seed, or NIF
bridge genuinely needs one, keep a narrow documented service API rather than a
generic `get_*!`, `change_*`, or `update_loaded_*` escape hatch. Move controller
behavior into the owning context instead of retaining a public helper solely
because a controller reaches through the boundary.

Avoid splitting one domain into extra modules solely to satisfy the ordering.
Small persistence contexts such as image votes may remain separate when they
own reusable transaction steps, but document that role and expose only those
steps actually required by the aggregate context.

### Documentation

Every public context function gets a spec and a doc in this order:

1. a short description of what it does and what it returns;
2. only potentially unexpected behavior: authorization action, parent scoping,
   error precedence, side effects, transactions, jobs/indexing/broadcasting, or
   deliberately accepted input oddities;
3. an `## Examples` section using realistic actor-first calls and all important
   success/error shapes.

Do not preserve surprising behavior merely because the current doc describes
it. Change the behavior first, then make the doc state the new contract. Replace
placeholder moduledocs such as “The X context” with domain ownership and
boundary descriptions. Internal functions should have comments only when the
reason or invariant is non-obvious; comments that restate code should go.

## Migration sequence

### Wave 0: characterize and establish the contract

- Follow `test/CONVENTIONS.md`: land any missing controller characterization in
  test-only changes before changing `lib/`. Cover every routed auth level, every
  write failure, malformed integer IDs, missing well-formed IDs, forbidden
  existing records, and mismatched nested-parent IDs.
- Record currently surprising behavior with `# NOTE:` and create the referenced
  `test/KNOWN-ODDITIES.md` if it is still absent. The implementation change may
  intentionally update those assertions in its later PR.
- Add a table-driven `Authorization`/`Loader` test matrix for anonymous, user,
  moderator, and admin actors across malformed, missing, and forbidden records.
- Implement the shared Loader/Authorization contract and migrate one small
  administrative context (SiteNotices is the preferred exemplar) before
  starting parallel context work.

### Wave 1: small and administrative contexts

Migrate Adverts, ArtistLinks, Autocomplete, Badges, Bans, Channels, Donations,
ModNotes, ModerationLogs, Notifications, Roles, Rules, SiteNotices,
UserFingerprints, UserIps, UserNameChanges, UserStatistics, and Versions. Use
these to settle naming, doc, typespec, and error conventions without the risk of
nested search-backed resources.

### Wave 2: account and profile boundaries

Migrate Users, Profiles, Conversations, Commissions, DnpEntries, and Reports.
Resolve which context owns cross-domain report changes and erasure callbacks,
replace direct role checks, and introduce named result structs for multi-part
profile/DNP responses before touching their controllers.

### Wave 3: forum hierarchy

Migrate Forums, Topics, Posts, Comments, Polls, PollOptions, and PollVotes as one
coordinated hierarchy. Delete public/anonymous bypass loaders, scope every child
to its parent, align new/edit and create/update prerequisites, and centralize
broadcast/notification side effects in the owning transaction.

### Wave 4: image, gallery, and tag hierarchy

Migrate Images, ImageFaves, ImageFeatures, ImageHides, ImageIntensities,
ImageVotes, Interactions, Galleries, DuplicateReports, Filters, Tags,
TagChanges, SourceChanges, and Activities. Keep OpenSearch serialization and
batch/worker APIs explicit, but separate them from controller APIs. Run these
serially where they touch shared indexes.

### Wave 5: enforcement and deletion

- Remove obsolete loaders, wrappers, direct `Repo` access from controllers,
  public raw CRUD, `verify_not_banned/1`, and resolved TODO/FIXME comments.
- Add a lightweight architectural check (Credo check or repository script) that
  flags context use of `Canada.Can.can?/3`, new controller `Repo` calls,
  undocumented public context functions, bang loaders on controller paths, and
  TODO/FIXME markers under `lib/philomena/`, including nested support modules.
- Re-run the public API inventory and ensure every retained non-controller
  function has an identified caller and documented reason to remain public.

## Context audit and priority

| Context group                          | Highest-risk remaining issue                                                         | Priority |
| -------------------------------------- | ------------------------------------------------------------------------------------ | -------- |
| Images, Posts, Topics, Comments        | Many hand-written parse/load/auth branches; public bypass loaders; nested visibility | Critical |
| Users, Reports, Profiles               | Large public surfaces, actor/user mixing, sensitive metadata and role checks         | Critical |
| Tags, TagChanges, Galleries            | Public worker/query helpers, unbounded or crash-prone paths, complex side effects    | High     |
| Forums, Polls, PollVotes               | Parent scoping and anonymous loaders                                                 | High     |
| Bans, Badges, Adverts, Channels        | Generic `:index` authorization and public raw CRUD                                   | High     |
| Commissions, Conversations, DnpEntries | Cast/shape TODOs and uneven form/write prerequisites                                 | High     |
| Remaining small contexts               | Mostly surface classification, docs, and consistent delegation                       | Normal   |

The individual files name the concrete functions and TODO/FIXME decisions for
each context.

## Verification gate for each context

1. Run its context tests and all controller tests that alias it inside the app
   container with `MIX_ENV=test`.
2. For search-backed contexts, follow the non-async index setup in
   `test/CONVENTIONS.md` and test both database and indexed side effects.
3. Run `mix format --check-formatted` and `mix credo`; ensure Dialyzer sees the
   normalized result types.
4. Search the context for `TODO`, `FIXME`, `Canada.Can`, direct role gates,
   bang loads, `@doc false`, and public functions with no external caller.
5. Run `philomena test` only after a complete migration wave, then run
   `npm run fmt`/Prettier for these Markdown plans if they are changed.

## Definition of done

- Malformed and missing locators have the same result for every actor; forbidden
  existing resources have one distinct result.
- Every nested route proves parent membership in its query.
- Form loaders enforce the same prerequisites as their writes.
- Controllers use only documented actor-scoped context APIs and contain no
  direct persistence or ability logic.
- Each context follows the requested layout and documentation order.
- Every TODO/FIXME in the context inventory is gone because its behavior was
  fixed, deliberately specified, or the obsolete code was removed.
