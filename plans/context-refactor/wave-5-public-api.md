# Wave 5 public API inventory

Wave 5 re-ran the public-function inventory after every domain wave was
complete. The audit used compiled documentation metadata, production call
sites, controller call sites, and explicit worker/maintenance entry points.

## Retained public surfaces

| Surface                                                                            | Identified callers                                                            | Reason it remains public                                                                                                            |
| ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Actor-first `load_*`, `new_*`, and mutation APIs                                   | Phoenix controllers and cross-context page assemblers                         | These are the request-independent domain boundary.                                                                                  |
| `put_*` transaction composers                                                      | Owning aggregate contexts                                                     | The schema-owning context must contribute locks, writes, counters, and after-commit effects to another context's `Philomena.Multi`. |
| `indexing_preloads/0` and `perform_reindex/2`                                      | `Philomena.SearchIndexer` and `IndexWorker` through the search-index behavior | Dispatch is dynamic, so ordinary static caller searches do not see it.                                                              |
| Named reindex, rename, erase, wipe, cleanup, backfill, and media-pipeline services | Workers, release tasks, seeds, and owning contexts                            | They are non-request operational boundaries and their docs state side effects or bang invariants.                                   |
| Generated subscription persistence functions                                       | `Philomena.Subscriptions` and the using context                               | Macro-generated cross-context calls cannot be private. They remain `@doc false` and are wrapped by actor-scoped context operations. |
| Image/gallery subscription notification callbacks                                  | `Philomena.Subscriptions` through dynamic callback dispatch                   | Dynamic `apply/3` requires a public callback; the source comments identify this exception.                                          |
| Authentication/token services without Actor                                        | Authentication controllers and mail/token workflows                           | The credential is the token; these are the documented exception to actor-first request APIs.                                        |

## Removed or narrowed during enforcement

- `Galleries.map_lock_errors/1` and
  `DuplicateReports.put_reject_open_reports/1` are private workflow mechanics.
- `PollOptions.load_option/2` was unused and is deleted.
- `Tags.create_tag/1` and StaticPages' raw create/update/bang-get functions
  existed only for tests. Fixtures now persist through schema changesets, and
  production exposes no test-only CRUD.
- StaticPages history now takes Actor, slug loading is missing-first, forms and
  writes share `verify_write_access/1`, and successful writes return the saved
  page rather than transaction maps.
- Context orchestration no longer calls `Canada.Can.can?/3` directly.

## Enforcement

`mix philomena.context_boundaries` parses source AST and fails on:

- direct Canada calls outside the authorization policy modules;
- controller calls to any Repo alias;
- public functions without an explicit `@doc` in every planned context; and
- controller calls to `Philomena` bang loaders.

`docker/app/run-test` runs the check immediately after formatting. The check is
covered by focused tests that prove aliased Repo calls and documented safe APIs
are classified correctly.
