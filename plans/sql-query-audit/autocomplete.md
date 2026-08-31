# Autocomplete SQL shape audit

Refs: master -> context-logic
Status: complete

--- status ---

Audit complete; all Autocomplete-owned SQL sites and the moved tag-autocomplete caller paths have reliable counterparts or are explicitly classified below.

--- top-level audit files ---
CONTEXT_STYLE.md
AGENTS.md (provided repository instructions)
test/CONVENTIONS.md
test/support/fixtures/autocomplete_fixtures.ex
test/philomena/autocomplete_test.exs
test/philomena_web/controllers/autocomplete/compiled_controller_test.exs
test/philomena_web/controllers/autocomplete/tag_controller_test.exs
priv/repo/migrations/20211219194836_create_autocomplete.exs
priv/repo/structure.sql
lib/philomena/autocomplete.ex
lib/philomena/autocomplete/autocomplete.ex
lib/philomena/autocomplete/generator.ex
lib/philomena/tags/local_autocomplete.ex
lib/philomena/tags/tag.ex
lib/philomena/tags.ex
lib/philomena/tags/tag_suggestion.ex
lib/philomena_web/controllers/autocomplete/compiled_controller.ex
lib/philomena_web/controllers/autocomplete/tag_controller.ex
lib/philomena_query/search.ex
lib/philomena/loader.ex
lib/philomena/release.ex
docker/app/run-development
docker/production/run-cron-daily
Query sites inspected: 9 (including the v1/v2 moved caller branches)

## Changed shapes

### Generate and atomically replace compiled artifact (`generate_autocomplete!/0`)

- Master: `lib/philomena/autocomplete.ex:40-53`, `generate_autocomplete!/0`: insert one row into `autocomplete`, then delete rows with `created_at < inserted_row.created_at`. The insert has no row-selection predicate; the cleanup is a table delete with a timestamp range predicate.
- context-logic: `lib/philomena/autocomplete.ex:22-33,69-73`, `replace_autocomplete!/1` called by `generate_autocomplete!/0`: inside `Repo.transact/1`, `DELETE FROM autocomplete` with no predicate, then insert one row. The transaction returns the inserted `Autocomplete` record.
- Delta: write operation changed from insert-then-predicate-delete to predicate-free delete-then-insert; deletion timing and transaction boundary changed. No joins, ordering, grouping, pagination, or preload.
- Index status: no index action
- Evidence: `priv/repo/migrations/20211219194836_create_autocomplete.exs:4-9` creates only the two-column `autocomplete` table (`content`, `created_at`) with no primary key or indexes; the migration is unchanged between refs. The master and context-logic structure dumps match here, and current `priv/repo/structure.sql:121-128` confirms there are no indexes or constraints on it. A full-table delete for the intended singleton artifact does not benefit from a `created_at` index; adding one would add write/storage cost without a demonstrated workload benefit. The structure/migration differences elsewhere in the comparison are unrelated to Autocomplete.
- Confidence: high

### Load latest compiled artifact (`show_compiled_autocomplete/0`, formerly `get_autocomplete/0`)

- Master: `lib/philomena/autocomplete.ex:30-34`, `get_autocomplete/0`: base table `autocomplete`, select schema row, `ORDER BY created_at DESC`, `LIMIT 1`, `Repo.one/1`.
- context-logic: `lib/philomena/autocomplete.ex:16-19,50-53`, `latest_query/0` and `show_compiled_autocomplete/0`: identical base table, ordering, and limit; `Loader.one/1` only translates `nil` to `{:error, :not_found}` after `Repo.one/1`.
- Delta: unchanged SQL shape; only function/API naming and result translation moved.
- Index status: no index action
- Evidence: the master and context-logic queries are both backed by the same two-column, keyless table definition (`priv/repo/structure.sql:121-128`); the table is intended to contain one current artifact after generation. No index candidate is justified for a one-row lookup. The existing `created_at DESC` query has no deterministic tie-breaker, but that is a correctness/determinism concern, not an index recommendation.
- Confidence: high

## Unchanged or non-index-relevant sites

- `Philomena.Autocomplete.Generator.tags_and_associations/0` (`lib/philomena/autocomplete/generator.ex:137-148`) is unchanged. Its `LocalAutocomplete.get_tags/1` and `get_associations/2` calls produce the following unchanged SQL sites:
  - `Philomena.Tags.LocalAutocomplete.top_tags/1` (`lib/philomena/tags/local_autocomplete.ex:55-64`): `tags`, filter `images_count > 0`, select `name/images_count/id`, `ORDER BY images_count DESC`, `LIMIT amount`.
  - `aliases_of_tags/1` (`:66-76`): `tags` filter `aliased_tag_id IN tag_ids`, inner join to `tags` through `aliased_tag`, select alias name and canonical name.
  - `associated_tag_ids/2` image sample (`:78-85`): `image_taggings` filter `tag_id = entry.id`, select `image_id`, `ORDER BY random()`, `LIMIT 100`.
  - `associated_tag_ids/2` association query (`:88-99`): `image_taggings` inner join `tags` on tagging tag id, filter joined `tags.images_count > entry.images_count` and tagging `image_id IN` the sample subquery, `GROUP BY tags.id`, `HAVING` the count ratio over `LEAST(entry.images_count,100) > 50`, `ORDER BY count(*) DESC`, `LIMIT amount`.
    These query definitions and the `Tag`/`Tagging` association schema (`lib/philomena/images/tagging.ex:8-12`) are unchanged for SQL-shape purposes. Current and master schema evidence has ordinary/unique coverage for `image_taggings(tag_id)`, unique `(image_id, tag_id)`, `tags(aliased_tag_id)`, and unique `tags(name)`/`tags(slug)` in `priv/repo/structure.sql:3950-3957,4293-4307`; `tags.id` is covered by `tags_pkey` at `:3094-3098`.
- Autocomplete tag lookup’s Postgres phase is unchanged despite moving ownership: master `lib/philomena_web/controllers/autocomplete/tag_controller.ex:58-89` private `search/2` and `:99-128` v1 call `Search.search_records(..., preload(Tag, :aliased_tag))`; context-logic `lib/philomena/tags.ex:567-614` exposes `Tags.autocomplete_tags/2`, with the same OpenSearch definition and `Search.search_records(preload(Tag, :aliased_tag))`. `PhilomenaQuery.Search.load_records_from_results/1` (`lib/philomena_query/search.ex:842-852`) still adds `WHERE tags.id IN (...)` and runs the same `aliased_tag` association preload. The changed result struct/mapping and controller movement are not SQL shape changes.
- `Autocomplete.Autocomplete` schema (`lib/philomena/autocomplete/autocomplete.ex:7-11`) has no associations or preload where clauses. The compiled controller (`lib/philomena_web/controllers/autocomplete/compiled_controller.ex:6-19`) only consumes the context result. Release/cron callers (`lib/philomena/release.ex:66-70`, `docker/app/run-development:23`, `docker/production/run-cron-daily:6`) invoke generation and add no query modifiers.

## New, deleted, moved, or ambiguous sites

- `get_autocomplete/0` was renamed/moved to `show_compiled_autocomplete/0`; its query has a reliable counterpart and is classified above as unchanged.
- The old controller-local tag lookup was moved to `Philomena.Tags.autocomplete_tags/2`; its OpenSearch request is outside this audit’s PostgreSQL scope, while its `tags.id IN (...)` record load and `aliased_tag` preload have reliable unchanged counterparts above.
- No Autocomplete-owned query site was deleted without a counterpart. No ambiguous Autocomplete SQL site was found.

## Follow-ups

- Correctness/determinism: `ORDER BY created_at DESC LIMIT 1` has no `id`/content tie-breaker, and the table has no primary key. The compiled-controller characterization test records that second-granularity timestamps can make the selected row nondeterministic (`test/philomena_web/controllers/autocomplete/compiled_controller_test.exs:26-36`). This is separate from index coverage.
- Correctness/concurrency: `replace_autocomplete!/1` is atomic for readers within one transaction, but concurrent generators can each delete then insert because the table has no uniqueness constraint or lock; the claimed “exactly one” invariant is not enforced at the database level. Validate whether generation is operationally single-flight before changing this in a follow-up.
- No Autocomplete index candidate remains after checking both refs’ structure dump and migration history. The generator’s `random()`, aggregate, and `HAVING` association workload is unchanged and belongs to the shared Tags/Image-tagging index review if workload evidence later warrants specialized analysis.
