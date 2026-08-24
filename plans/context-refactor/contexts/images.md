# Images context plan

Source: `lib/philomena/images.ex`; consumers: the largest HTML/JSON/RSS
controller set, workers, search/indexing, media processing, and other contexts.

## Implementation status

Complete for wave 4.

- One Actor-first member loader now parses and fetches a real image before
  action authorization. Malformed and missing locators are actor-independent,
  hidden images no longer leak through API/oEmbed bypasses, and the only bang
  loader is explicitly named for invariant-enforced indexing jobs.
- New/upload, metadata edits, moderation, subscriptions, and image interactions
  share the write-access gate. Sensitive uploader/anonymity changes also need a
  per-image action, while page interaction controls account for authorization,
  locks, forced filters, and actor state.
- Search scope no longer substitutes for Actor. Navigation returns controlled
  parser errors, uses the shared visibility filters, and parser-owned referenced
  tag metadata replaces the Images-specific recursive query matcher.
- Raw loaded-record mutations are private. Request APIs, merge composition, user
  erasure, indexing, thumbnail repair, and purge workers use narrow named
  boundaries with documented side effects.
- Image creation and description/source/tag mutations own their firehose
  broadcasts. State-dependent moderation locks the image row; database changes,
  counters/reports, and audit logs commit together, with indexing, media, CDN,
  and broadcast work deferred until success.
- Context and controller coverage pins malformed, missing, hidden, forbidden,
  forced-filtered, banned, state-transition, audit, broadcast, navigation, and
  search behavior across anonymous, user, moderator, and admin actors.

## Findings

- The 3,500-line module exposes loaded-record CRUD, controller orchestration,
  navigation/search, indexing/worker functions, interaction toggles, and
  subscription/notification helpers as one interleaved public surface.
- ID handling ranges from `get_image!` and raising `load_image/1` to repeated
  `IntegerId.parse`/query/authorize `with ... else` blocks. A TODO asks to make
  `load_image/1` non-raising, and `load_public_image/1` is an actor bypass.
- Many member operations hand-roll parse/load/auth. Some authorize class-like
  subjects or sensitive `:ip_address` access but explicitly perform no per-image
  authorization. `load_image_page/3` computes interaction controls without an
  actor gate.
- New/edit uses `verify_not_banned/1` while upload/mutations use
  `verify_write_access/1`. Navigation/search functions can crash on invalid
  queries.
- `preload_created_image/1` has a FIXME questioning its public status. Three
  update paths have FIXMEs asking why broadcasting was not moved into context
  logic.

## Work

### Split the API surface conceptually

- Keep one module if desired, but group private mechanics first and then public
  APIs by controller reads, controller writes, and documented service/worker
  operations. Consider private submodules for transaction construction or index
  serialization only when that reduces ownership ambiguity.
- Make raw loaded-record CRUD/modifiers (`create_image`, `hide_loaded_image`,
  merge/file/source/tag loaded updates, lock mechanics) private. Expose narrow
  named services for workers/eraser/merge only when cross-module use is real.
- Make `preload_created_image/1` private and return the fully prepared image from
  the public upload/create transaction instead.

### Normalize loading and authorization

- Introduce one safe image member loader supporting explicit preloads and an
  action. It parses, loads a real image, applies hidden/deleted visibility, then
  authorizes; use it for every controller ID path. Delete `get_image!`, raising
  `load_image`, `load_public_image`, and repeated local parse branches from
  controller flows.
- Preserve a separate clearly documented invariant-only worker loader if jobs
  must fail loudly. Its name must make the bang/service semantics obvious.
- Require `verify_write_access/1` for new/upload/edit and every interaction or
  mutation. Actor-gate interaction controls on `load_image_page/3`, including
  hidden/locked/forced-filter cases.
- For uploader/anonymity changes, require both the sensitive metadata permission
  and an image-specific action. Do not let permission to view IP data authorize a
  modification of every image.

### Queries, side effects, and TODOs

- Normalize invalid search/navigation queries to explicit parse errors or
  not-found results; `find_consecutive_image/2` must not crash. Share the
  visibility query with show/random/related/navigation to prevent drift.
- Carry Actor separately from `Images.Search.Scope`; limit Scope to compiled
  filter, query params, and pagination so it cannot become an authorization
  surrogate. Update every search caller and Scope's type/docs.
- Have the query parser/AST expose referenced tag names and delete Images.Search's
  recursive query-shape matcher. Query optimization belongs in the parser/search
  layer, not a private set of partial OpenSearch-map clauses.
- Put description/source/tag broadcasts into the same public context operation
  that owns persistence, with an outbox/after-commit strategy if they cannot be
  transactional. Resolve all three broadcast FIXMEs consistently.
- Audit approve/feature/destroy/locks/hash/repair/file/hide/batch operations for
  action-specific abilities and atomic moderation logs, indexing, notifications,
  and object-storage changes.
- Keep index/reindex/purge/migration APIs documented as service APIs and separate
  from controller docs. State eventual-consistency and job behavior.

## TODO/FIXME resolution

- Replace raising `load_image/1` with the shared safe loader.
- Actor-gate page interaction capabilities.
- Return controlled errors for invalid navigation/search queries.
- Resolve the Search.Scope Actor-substitution FIXME and search-parser
  optimization TODO as part of the search API migration.
- Make `preload_created_image/1` private.
- Move all missing broadcasts into the owning context operation.

## Verification

- Build a shared matrix used by every image member controller: malformed,
  missing, hidden, deleted, forced-filtered, and forbidden IDs for anonymous,
  user, owner/uploader, moderator, and admin actors.
- Add form/write prerequisite parity, sensitive metadata, navigation/search
  parser, each moderation action, interaction idempotency/counters, subscriptions,
  media/object failure, transaction/log/broadcast, and OpenSearch assertions.
- Migrate in slices and run the directly affected controller files plus
  `images_test.exs`; run search tests non-async with index clearing.
