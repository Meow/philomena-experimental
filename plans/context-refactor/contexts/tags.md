# Tags context plan

Source: `lib/philomena/tags.ex`; consumers: HTML/JSON tag search/show/edit/detail,
alias/image/watch/reindex controllers, Images, workers, and autocomplete.

## Findings

- The module combines raw tag/alias/delete/count/index mechanics with
  controller-facing APIs. Many later mutations repeat authorize/load/presence
  `else` branches.
- Loaders vary among slug `Repo.get_by`, alias resolution, page/detail assembly,
  and direct name-returning helpers. Form/mutation write prerequisites are not
  consistently centralized.
- TODOs question string type-casting in `copy_tags/2`, request a result struct for
  `tag_detail/2`, and propose collapsing cleanup into one delete-returning-IDs
  statement.
- Several powerful worker/index APIs are necessarily cross-module, but their
  service role is mixed with controller documentation.

## Work

- Create one safe slug/name locator policy: distinguish canonical-only lookup
  from alias resolution in function names, fetch a real tag, then authorize the
  requested action. Replace repeated local `else` translations and ensure
  aliases cannot bypass visibility/edit rules.
- Apply `verify_write_access/1` consistently to edit forms and every mutation,
  then action-specific tag authorization. Keep watch/unwatch actor-scoped and
  idempotent.
- Introduce a typed `TagPage`/`TagDetail` result for detail data and move page
  assembly behind it. Normalize search parser errors.
- Fix `copy_tags/2` with explicit typed select/casting or, preferably, schema
  values that do not round-trip through strings; add regression coverage before
  removing the TODO.
- Rewrite `cleanup!/0` as a single delete returning affected tag/image IDs if SQL
  permits, then enqueue/reindex from that result. Otherwise document why batching
  is required instead of retaining a speculative TODO.
- Make raw loaded modifiers/query helpers private. Keep worker/index/delete/
  alias services documented in a separate public section with side effects and
  transaction/job boundaries.

## Verification

- Matrix-test malformed/missing/canonical/aliased/forbidden slugs for every
  member action; form/write parity; alias cycles/conflicts; copy type handling;
  detail struct; cleanup returned IDs; watch state; image changes; and search
  indexing.
