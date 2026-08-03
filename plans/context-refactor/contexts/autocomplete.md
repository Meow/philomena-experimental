# Autocomplete context plan

Source: `lib/philomena/autocomplete.ex`; consumer: compiled autocomplete API and
the generator process.

## Findings

- `get_autocomplete/0` and `generate_autocomplete!/0` are a small public surface,
  but only the former is controller-facing and the latter is an operational
  service with bang semantics.
- The context has no actor because the compiled artifact is public; that
  exception should be explicit rather than made to resemble an authorized CRUD
  context.
- Documentation does not fully state cache/file behavior, generator side
  effects, or what callers see before the first artifact exists.

## Work

- Keep `get_autocomplete/0` public and unauthenticated, documenting the public
  data contract and missing/stale artifact behavior with examples.
- Keep generation as a clearly named operational API only if a scheduler/task
  calls it; otherwise move it into `Autocomplete.Generator`. Document why it
  raises and whether artifact replacement is atomic.
- Ensure private file/cache access and encoding helpers precede the public API.
  Replace any direct controller filesystem knowledge with this context result.

## Verification

- Test first-read/no-file, successful generation/read, malformed artifact, and
  atomic replacement behavior without relying on production paths.
