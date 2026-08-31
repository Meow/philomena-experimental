# Filters SQL shape audit

Refs: master -> context-logic  
Status: complete

Query sites inspected: 8

--- files ---

- `lib/philomena/filters.ex`
- `lib/philomena/filters/filter.ex`
- `lib/philomena/filters/query.ex`
- `lib/philomena/filters/visibility.ex`
- `lib/philomena/filters/filter_page.ex`
- `lib/philomena/filters/filter_selection.ex`
- `lib/philomena/images/filtering.ex`
- `lib/philomena_web/controllers/filter_controller.ex`
- `lib/philomena_web/plugs/current_filter_plug.ex`
- `lib/philomena_web/plugs/filter_id_plug.ex`
- `lib/philomena_web/plugs/filter_select_plug.ex`
- `test/philomena/filters_test.exs`
- `test/philomena_web/controllers/filter_controller_test.exs`
- `priv/repo/structure.sql`

--- query shapes ---

The following are PostgreSQL/Ecto shapes owned by Filters. Search definitions
and `Visibility.search_filters/1` are OpenSearch request construction and are
not included as SQL.

| Operation / branch                                      | master shape                                                                                                                                                                  | context-logic shape                                                                                                                                                                                          | classification                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Default filter lookup                                   | `filters` member lookup: `system = true AND name = 'Default'`, `Repo.one!`                                                                                                    | same                                                                                                                                                                                                         | unchanged; the existing `index_filters_on_system` partial index covers the fixed system predicate, while `name` is additionally indexed                                                                                                                                                                                    |
| Filter index, anonymous                                 | controller ran `filters WHERE system = true`, preload users, `Repo.all`                                                                                                       | context runs `filters WHERE system = true ORDER BY id ASC`, preloads users, `Repo.all`                                                                                                                       | changed, index-relevant: adds ordering; partial `(system) WHERE system=true` does not provide `id` ordering. This is likely a small system-filter set and no candidate is justified without plans/cardinality                                                                                                              |
| Filter index, signed-in own branch                      | controller ran `filters WHERE user_id = actor.id`, preload users, `Repo.all`                                                                                                  | `filters WHERE user_id = actor.id ORDER BY id ASC`, user preload, `Repo.paginate` (count plus page query, with limit/offset)                                                                                 | changed, index-relevant: adds ordering and pagination. Existing `index_filters_on_user_id(user_id)` covers selection but not order; conditional candidate `(user_id, id)` could remove the sort for frequent/deep pages                                                                                                    |
| `user_filters/2`                                        | no counterpart (new context API extracted from the old index branch)                                                                                                          | same owner-page shape: `WHERE user_id = actor.id ORDER BY id ASC`, preload user, count/page pagination                                                                                                       | new/deleted/unpaired; this is the paginated form of the old own-list workload, not a new logical dataset. Existing user-id index covers filtering; `(user_id,id)` is only a conditional candidate                                                                                                                          |
| `system_filters/2`                                      | no counterpart (old index system branch was unpaginated)                                                                                                                      | `WHERE system = true ORDER BY id ASC`, Scrivener count/page                                                                                                                                                  | new/deleted/unpaired; extracted/paginated old workload. Existing partial system index covers filtering, not ordering; no standalone index recommendation without evidence                                                                                                                                                  |
| Recent + own filter selection                           | two-branch `UNION ALL`: recent `id IN ^recent_ids` (up to 11 IDs; no limit/order) union own `user_id = actor.id LIMIT 10`; selected `id,name,recent`                          | same union, but both branches use a struct projection; own branch adds `ORDER BY id ASC`; recent branch adds `LIMIT 10`; `Repo.all`, then in-memory split/sort                                               | changed, index-relevant: own branch now has an order requirement. The recent branch is PK `IN` and is covered by `filters_pkey`; existing `user_id` index covers equality. Conditional `(user_id,id)` candidate as above; no index for the recent branch                                                                   |
| Filter member/show and based-on load                    | old plug/controller used `Repo.get(Filter,id)` (the `new based_on` query additionally had `id = ? AND (system OR public OR owner)`); authorization was in the plug/controller | `Loader.fetch_and_authorize` performs PK lookup then application authorization; `show_filter_page` follows with two `tags WHERE id IN ^tag_ids ORDER BY name` queries                                        | changed, likely not index-relevant: visibility moved from SQL predicate to authorization after PK fetch; tag lookups use tag PKs. No missing index. Visibility semantics should be reviewed separately, but this is not an index recommendation                                                                            |
| Filter tag replacement (`put_replace_tag_references/5`) | no counterpart                                                                                                                                                                | within a transaction, select IDs and `UPDATE filters SET hidden_tag_ids = array_replace(...) WHERE hidden_tag_ids @> ARRAY[old_id]`; same pair for `spoilered_tag_ids`; selected IDs are used for reindexing | new/deleted/unpaired and index-relevant: new array-containment bulk update and matching ID scans. No array index exists. Conditional candidates are separate GIN indexes on `hidden_tag_ids` and `spoilered_tag_ids`; validate frequency/selectivity and `EXPLAIN` first because each update also writes the indexed array |
| Reindex worker lookup                                   | `filters` preload `user`, `field(column) IN ^condition`, search serialization                                                                                                 | same SQL                                                                                                                                                                                                     | unchanged; `column` is trusted worker input and the usual `id IN` path is PK-covered                                                                                                                                                                                                                                       |

Association/follow-up SQL observed in these operations is covered by existing
keys: `Repo.preload(user, [:current_filter, :forced_filter])` joins from user
foreign keys to `filters.id` (primary key), `preload(:user)` joins to
`users.id` (primary key), and page tag loads use `tags.id` (primary key).
`Repo.preload(actor.user, :settings)` is a Users-owned association and should
be handled by the shared/Users audit.

--- index evidence ---

`context-logic:priv/repo/structure.sql` has:

- `filters_pkey (id)`;
- `index_filters_on_name (name)`;
- partial `index_filters_on_system (system) WHERE system = true`; and
- `index_filters_on_user_id (user_id)`.

The schema/index dump is unchanged between the two refs for these indexes. No
`EXPLAIN` was run because the audit environment does not provide a safely
initialized test database in this read-only pass. Consequently the composite
`(user_id,id)` and array GIN suggestions above are conditional candidates, not
recommendations for immediate migration. The system list is expected to be
small; the partial system index is probably sufficient despite the sort.

--- correctness / review notes ---

- The old `new based_on` SQL embedded visibility (`system OR public OR owner`),
  while the new Loader fetches by primary key and authorizes in application
  code. This appears intended, but should be checked as a semantic
  authorization change independently of indexing.
- `recent_and_user_filters/1` now limits the recent-ID branch to 10 and orders
  the own branch by `id`; this changes result cardinality/order (the old recent
  branch could return the current filter plus ten recent IDs). It is an
  intentional-looking selection behavior change, not an additional index
  candidate beyond the owner ordering path.
- `Filters.ImageFilter` and `Images.Filtering` perform in-memory evaluation;
  they issue only PK/filter and tag preloads, not image SQL query shapes.
