# ModNotes SQL shape audit

Refs: master -> context-logic
Status: complete

--- status ---

ModNotes has changed SQL shapes. Target-scoped embedded reads now add a
`LIMIT 250`, and current context operations add explicit target/member lookup
queries and target preloads. The note-target predicates remain the same three
polymorphic foreign-key equality shapes. No application code, migration, test,
or schema file was changed by this audit.

--- files ---

lib/philomena/mod_notes.ex
lib/philomena/mod_notes/mod_note.ex
lib/philomena/mod_notes/target.ex
lib/philomena/loader.ex
lib/philomena/reports.ex
lib/philomena/dnp_entries.ex
lib/philomena/profiles.ex
lib/philomena/reports/report.ex
lib/philomena_web/controllers/admin/mod_note_controller.ex
lib/philomena_web/controllers/admin/report_controller.ex
lib/philomena_web/controllers/dnp_entry_controller.ex
lib/philomena_web/controllers/profile_controller.ex
priv/repo/migrations/20260719123610_add_notable_association_to_mod_notes.exs
priv/repo/migrations/20260719123611_drop_notable_from_mod_notes.exs
priv/repo/structure.sql

Query sites inspected: 18

## Changed shapes

### Target-scoped embedded note reads (`list_all_mod_notes_for_target/2` -> `list_for_target/3`)

- Master: `lib/philomena/mod_notes.ex:26-32`, called from the old report,
  DNP, and profile controller loaders. Base `mod_notes`; one fixed dynamic
  predicate, `user_id = $1`, `report_id = $1`, or `dnp_entry_id = $1`; selected
  note rows; `ORDER BY id DESC`; no limit. The operation then preloads the
  moderator and the three target associations (with nested report/DNP
  preloads).
- context-logic: `lib/philomena/mod_notes.ex:78-91`, called by
  `DnpEntries.show_dnp_entry/3`, `Profiles.load_mod_notes/3`, and
  `Reports.mod_notes/3`. Before the note query, `Loader.fetch_and_authorize/5`
  performs a target-table primary-key lookup. The note query has the same
  base table, selected columns, one of the same three equality predicates, and
  `ORDER BY id DESC`, but adds `LIMIT 250`. The same moderator/target preload
  set follows.
- Delta: added target member lookup and a bounded newest-first result; target
  filter column, operator, ordering, and boolean shape are unchanged.
- Index status: candidate
- Evidence: `priv/repo/structure.sql` in both refs contains
  `mod_notes_user_id_index`, `mod_notes_report_id_index`, and
  `mod_notes_dnp_entry_id_index`, each a partial B-tree on its target column
  with `IS NOT NULL`, so each equality predicate is covered. `mod_notes_pkey`
  and the target-table primary keys cover the new member lookups. None of the
  target indexes includes the `id DESC` tie/order column. A possible follow-up
  is three equivalent partial indexes, respectively
  `(user_id, id DESC) WHERE user_id IS NOT NULL`,
  `(report_id, id DESC) WHERE report_id IS NOT NULL`, and
  `(dnp_entry_id, id DESC) WHERE dnp_entry_id IS NOT NULL`; this needs a
  representative `EXPLAIN` and workload/cardinality evidence before adoption.
- Confidence: high

### Admin target-filtered page (`list_mod_notes_for_target/3` -> `list_mod_notes/4`)

- Master: `lib/philomena/mod_notes.ex:63-67` builds
  `mod_notes WHERE <one target column> = $1 ORDER BY id DESC` and passes it to
  the paginated `list_mod_notes/3` path. The data query has the pagination
  `LIMIT/OFFSET`; the paginator also issues the corresponding count query with
  the same target predicate.
- context-logic: `lib/philomena/mod_notes.ex:118-126` parses one target,
  authorizes/loads its target row with a primary-key lookup, then builds the
  same filtered paginated note query and count shape. A valid single target
  therefore has the same note-table filter, ordering, pagination, and count
  shape as master; target/moderator associations are preloaded as before.
- Delta: explicit target lookup was added; the final note relation for a
  valid target is unchanged. The target parser now rejects multiple supplied
  targets instead of selecting the first parseable one.
- Index status: no index action
- Evidence: target equality is covered by the three existing partial target
  indexes; target and note member lookups use primary keys. The optional
  composite indexes above would also help this page's same newest-first shape,
  but no new ordering/filter shape was introduced here and there is no plan
  evidence to justify them independently.
- Confidence: high

### Admin target-parameter fallback branch

- Master: `lib/philomena_web/controllers/admin/mod_note_controller.ex:17-21`
  uses the first parseable target parameter. If one is valid, the note query
  is target-filtered; if none is valid, it is the unfiltered page query.
- context-logic: `lib/philomena/mod_notes.ex:120-126` requires exactly one
  parseable target. Multiple targets, or a malformed target alongside another
  valid target, fall through to the unfiltered `mod_notes ORDER BY id DESC`
  page rather than the master target equality query.
- Delta: for those parameter branches, a target equality predicate is removed
  and the query changes to a full collection page; pagination and ordering stay
  the same.
- Index status: no index action
- Evidence: the filtered branch is covered by the existing partial target
  indexes, while the unfiltered newest-first branch is supported by the note
  primary-key index on `id`. This is primarily a correctness/authorization
  behavior change, not a missing-index finding.
- Confidence: high

### Note member edit/update/delete (`get_mod_note!/1` and authorization plug -> `Loader.fetch_and_authorize/5`)

- Master: `lib/philomena/mod_notes.ex:122` and the admin resource plug load a
  note by primary key (`WHERE id = $1`). Update and delete then use the loaded
  row, so their write predicates remain the primary key.
- context-logic: `lib/philomena/mod_notes.ex:55-57,218-220,240-242,280-282`
  loads by the same `id = $1` predicate but requests
  `ModNote.target_preloads/0`; edit, update, and delete still select/update/
  delete by the note primary key. The new Multi audit-log insert is owned by
  the shared ModerationLogs operation and has no changed row-selection
  predicate here.
- Delta: same note member lookup and write target; current edit/update/delete
  additionally issue association preload queries. Those preloads use
  `users/reports/dnp_entries WHERE id IN (...)` and unchanged nested target
  preloads.
- Index status: no index action
- Evidence: `mod_notes_pkey` covers the note lookup and write predicates;
  parent primary keys cover the association `IN` lookups. The existing
  `index_mod_notes_on_moderator_id` covers the note-to-moderator foreign key.
- Confidence: high

### New/create target loading (`new_mod_note/2`, `create_mod_note/2`)

- Master: the old new form constructed a struct from parsed parameter IDs, and
  the old create path inserted the supplied target foreign-key value; neither
  ModNotes operation loaded the target row before building/inserting the note.
- context-logic: `lib/philomena/mod_notes.ex:146-153,174-181` parses one typed
  target and performs `Loader.fetch_and_authorize/5`, which is a target-table
  `WHERE id = $1` lookup, before the changeset/new insert. The note insert
  itself has no row-selection predicate.
- Delta: new target existence/authorization member lookups were added; no
  note-table filter or write-target predicate changed.
- Index status: no index action
- Evidence: `users_pkey`, `reports_pkey`, and `dnp_entries_pkey` cover these
  lookups. This is a new query workload but not a candidate for a secondary
  index.
- Confidence: high

## Unchanged or non-index-relevant sites

- `list_mod_notes/3`'s unfiltered admin page became the no-target branch of
  `list_mod_notes/4`: base `mod_notes`, `ORDER BY id DESC`, paginator data
  `LIMIT/OFFSET`, count query, moderator preload, and target preloads are the
  same. Locations: master `lib/philomena/mod_notes.ex:85-92`; current
  `lib/philomena/mod_notes.ex:124-126` and `:46-53`.
- `create_mod_note` still inserts one `mod_notes` row with the moderator and
  exactly one target foreign key; the explicit target columns and check
  constraint predate this comparison. Current transactional audit logging is
  an additional shared write, not a changed row-selection query.
- `ModNote.target_preloads/0` is unchanged between refs. Its association SQL
  is primary-key/`IN` loading for `user`, `report`, `dnp_entry`, and nested
  associations; moving rendering before/after preload does not change SQL
  shape.
- `lib/philomena/mod_notes/mod_note.ex` only changes a type declaration and a
  default changeset argument; no SQL shape changes found there.
- `lib/philomena/reports/report.ex` target preloads are unchanged. The moved
  report, DNP, and profile callers now delegate to their contexts, but their
  ModNotes consumer relation is represented by the target-scoped finding
  above.

## New, deleted, moved, or ambiguous sites

- `list_mod_notes_by_query_string/3` at master `lib/philomena/mod_notes.ex:50-54`
  is deleted in context-logic and has no current caller found. Its old shape
  was `mod_notes WHERE body ILIKE '%<query>%' ORDER BY id DESC` with paginated
  data/count queries. This was a leading-wildcard text search and has no
  current workload or index action; a generic B-tree would not cover it.
- The old `load_and_authorize_resource`/controller note loaders were moved
  into `Philomena.ModNotes`, `Philomena.Loader`, `Reports`, `DnpEntries`, and
  `Profiles`. The stable note query counterpart is recorded above; the new
  target/member lookups are primary-key covered. `Loader` and the
  `ModerationLogs.put_log` transaction are shared findings and should not be
  duplicated in a context-specific index recommendation.
- No ambiguous ModNotes-owned Ecto query remained after tracing the old admin,
  report, DNP, and profile callers and the current context delegates.

## Follow-ups

- Correctness review: the current admin `list_mod_notes/4` inner `else` treats
  target parse failures and target authorization failures alike and falls back
  to the unfiltered note page. In particular, an unauthorized target can cause
  all notes to be listed to an actor who can index ModNotes. This should be
  reviewed separately from indexing.
- Plan evidence is still missing for the optional three-index family
  `(target_id, id DESC)` partial indexes. Check representative filtered page
  and embedded queries with `EXPLAIN (FORMAT JSON)`, plus table size, target
  cardinality, and request frequency, before accepting their write/storage
  cost. Existing single-column partial indexes are sufficient predicate
  coverage and are the current no-regret baseline.
- Shared-query link: `Philomena.Loader` member loading and
  `ModerationLogs.put_log` belong in the shared audit; this report only records
  their participation in ModNotes operations.
