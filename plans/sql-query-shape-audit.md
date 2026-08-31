# SQL query-shape audit for `context-logic`

## Outcome

Produce an evidence-backed inventory of PostgreSQL query shapes that differ
between `master` and `context-logic`, and a deduplicated list of database-index
candidates. The audit is read-only: it must not add migrations or change
application code. Its output should make it possible to decide which index
changes, if any, belong in a follow-up change.

The comparison is semantic. Moving a query from a controller to a context is
not itself a shape change, while adding a visibility predicate, changing a
join, or changing an `ORDER BY` is. The final query after all context/query
builder modifiers have been applied is the unit of comparison.

## Deliverables

Create these working documents under `plans/sql-query-audit/` while the review
is in progress:

- one `<context>.md` report for every context in the assignment matrix below;
- `shared.md` for queries used by more than one context and for
  `Loader`/authorization/visibility helpers; and
- `summary.md`, containing the deduplicated index recommendations and a list
  of changed queries that need no index action.

The per-context reports may be created in parallel. The shared report and
summary are written only after the individual reports are available.

## Scope and inventory rules

Each agent owns one named context, even when that context has no changed SQL.
It must report `no SQL shape changes found` rather than silently omitting the
context. Include:

- queries in `lib/philomena/<context>.ex` and its nested modules;
- queries moved into the context from `lib/philomena_web` or another context;
- Ecto queries used for `Repo.all/one/one!/exists?/aggregate/stream`,
  `Repo.preload`, `Repo.delete_all`, `Repo.update_all`, and equivalent
  `Philomena.Multi` operations;
- query builders, visibility scopes, association preload queries, count and
  existence queries, and queries used by workers or maintenance code that are
  owned by the context; and
- query definitions in schemas when their association `where` clauses affect
  SQL issued by a context preload.

Do not treat these as PostgreSQL query changes:

- OpenSearch request bodies, mappings, search scopes, or index serialization;
- a query whose only difference is module/function movement, aliases,
  whitespace, bind names, or the order of independent `AND` predicates;
- a preload that is merely reordered when it generates the same SQL; or
- a write changeset that does not alter the database row-selection predicate.

The last exclusion is intentionally narrow: `UPDATE` and `DELETE` predicates,
upsert conflict targets, and locking queries are in scope when their lookup
columns changed, because they can also need an index.

## Assignment matrix

The rows below are review waves. Within a row, assign one agent per named
context; the wave grouping is for coordination, not for combining reports.
Nested modules in parentheses belong to the named context and should not get a
second report.

### Wave A: small and supporting contexts

| Context            | Likely files and special focus                                                                             |
| ------------------ | ---------------------------------------------------------------------------------------------------------- |
| `Activities`       | `activities.ex`, `activities/front_page.ex`; homepage feeds and ordering                                   |
| `Adverts`          | `adverts.ex`, advert/server/uploader modules; active-date and random selection                             |
| `ArtistLinks`      | `artist_links.ex`, query builder/form, automatic verifier; tag/user joins and verification queues          |
| `Autocomplete`     | `autocomplete.ex`, generator; rebuild and lookup queries                                                   |
| `Badges`           | `badges.ex`, award/badge/uploader modules; badge-user listing order                                        |
| `Bans`             | `bans.ex`, finder and fingerprint/subnet/user query builders/forms; compound ban lookup predicates         |
| `Channels`         | `channels.ex`, channel query builder and automatic updater; provider/name filters and subscriptions        |
| `Donations`        | `donations.ex`, donation schema; user/date ordering                                                        |
| `ModNotes`         | `mod_notes.ex`, target module; polymorphic target filtering and ordering                                   |
| `ModerationLogs`   | `moderation_logs.ex`, paths/schema; actor/target filters and history order                                 |
| `Notifications`    | `notifications.ex`, notification category/creator modules; per-user read/date ordering and fan-out lookups |
| `Roles`            | role schema/form and role lookups; report zero if there is no changed SQL                                  |
| `Rules`            | `rules.ex`; reportable-rule and version ordering                                                           |
| `SiteNotices`      | `site_notices.ex`; active-window and administrative ordering                                               |
| `StaticPages`      | `static_pages.ex`, version modules; slug/history ordering                                                  |
| `UserFingerprints` | `user_fingerprints.ex` and nested schemas; user history and latest-row queries                             |
| `UserIps`          | `user_ips.ex` and nested schemas; user history and latest-row queries                                      |
| `UserNameChanges`  | `user_name_changes.ex`; user/history lookups and ordering                                                  |
| `UserStatistics`   | `user_statistics.ex`; per-user/date aggregation                                                            |
| `Versions`         | `versions.ex` and legacy backfill; resource/version history ordering                                       |

### Wave B: account and profile contexts

| Context         | Likely files and special focus                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `Users`         | `users.ex`, `users/*`, `user_wipe.ex`; account locators, tokens, profile listings, admin queues, erasure/wipe queries     |
| `Profiles`      | `profiles.ex`, `profiles/*`; assembled profile pages and IP/fingerprint/source/tag history queries                        |
| `Conversations` | `conversations.ex`, conversation/message/query modules; participant filters, unread state, lateral/latest-message queries |
| `Commissions`   | `commissions.ex`, directory/item/query builder/form; open commission filters, item joins, random ordering                 |
| `DnpEntries`    | `dnp_entries.ex`, dnp entry/listing/query builder/form; tag/user/status filters and counts                                |
| `Reports`       | `reports.ex`, report/search-index/legacy-converter modules; open/claimed filters, target joins, claim/order queries       |

### Wave C: forum hierarchy

| Context       | Likely files and special focus                                                                                            |
| ------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `Forums`      | `forums.ex`, forum page/index/visibility/transaction workflow; access-level and slug predicates                           |
| `Topics`      | `topics.ex`, topic visibility/form modules; forum-scoped slug, hidden/deleted filters, last-post order                    |
| `Posts`       | `posts.ex`, post/post-version/query modules; topic-scoped IDs, search/list ordering, history queries                      |
| `Comments`    | `comments.ex`, comment/query/visibility/history/version modules; image visibility, moderation state, search/count queries |
| `Polls`       | `polls.ex`, poll schema; topic-scoped poll loading                                                                        |
| `PollOptions` | `poll_options.ex`, option schema; poll-scoped option ordering                                                             |
| `PollVotes`   | `poll_votes.ex`, ballot/schema; voter/poll existence and lock queries                                                     |

### Wave D: image and interaction contexts

| Context            | Likely files and special focus                                                                                                           |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `Images`           | `images.ex`, `images/*`; image visibility, approval queues, navigation/random/related SQL, tag/source preloads, batch and worker lookups |
| `ImageFaves`       | `image_faves.ex` and schema; user/image uniqueness and listing queries                                                                   |
| `ImageFeatures`    | `image_features.ex` and schema; image/feature lookup predicates                                                                          |
| `ImageHides`       | `image_hides.ex` and schema; user/image existence and delete predicates                                                                  |
| `ImageIntensities` | `image_intensities.ex` and schema; duplicate comparison lookup columns                                                                   |
| `ImageVotes`       | `image_votes.ex` and schema; user/image uniqueness, counts, and batch deletion                                                           |
| `Interactions`     | `interactions.ex`; aggregate image interaction preload and counter queries                                                               |

### Wave E: gallery, filter, tag, and source contexts

| Context            | Likely files and special focus                                                                                                                       |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Galleries`        | `galleries.ex`, gallery page/query/form/reorder modules; owner/public filters, image ordering, pagination and locking                                |
| `DuplicateReports` | `duplicate_reports.ex`, comparison/query/search-result/transaction modules; intensity joins, report state, priority/order queries                    |
| `Filters`          | `filters.ex`, filter visibility/selection/page/image-filter modules; owner/public/current filters and search ordering                                |
| `Tags`             | `tags.ex`, tag schema, local autocomplete, quick tag table, query/search modules; canonical/alias predicates, image-count ordering, graph traversals |
| `TagChanges`       | `tag_changes.ex`, limits/tag-change-tag/query/search modules; actor/resource filters, image visibility, history order and counts                     |
| `SourceChanges`    | `source_changes.ex`, query builder and schema; image/user/IP/fingerprint history filters and order                                                   |

`Maintenance`, `SiteStatistics`, `DataExports`, and standalone worker modules
are supporting persistence owners rather than controller contexts. The
coordinator assigns their changed SQL to the closest owning context when
possible; otherwise record it in `shared.md`. The same rule applies to
`Loader`, `Authorization`, `RateLimiter`, `Subscriptions`, and
`Philomena.Multi`: review them once in `shared.md`, then link to that finding
from affected context reports.

## Common procedure for every context agent

### 1. Establish the complete source set

Start with both refs, not only the current files:

```sh
git diff --name-status --find-renames master..context-logic -- lib/
git grep -n -E 'Repo\.(all|one!?|exists\?|aggregate|stream|delete_all|update_all)|Repo\.preload|from\(|where:|order_by:|join:|left_join:|inner_join:|group_by:|having:' master -- lib/philomena lib/philomena_web
rg -n -E 'Repo\.(all|one!?|exists\?|aggregate|stream|delete_all|update_all)|Repo\.preload|from\(|where:|order_by:|join:|left_join:|inner_join:|group_by:|having:' lib/philomena lib/philomena_web
```

Use the diff and call sites to find queries that were moved, split, inlined,
or deleted. Search for callers in both refs so a query is not missed merely
because its old controller helper disappeared. For each query, identify the
public operation, all relevant parameter branches, and the final relation
after visibility, authorization, pagination, preload, and ordering modifiers.

### 2. Record the normalized shape at both refs

For each operation that exists at both refs, capture a compact normalized
record containing:

- base table and selected columns;
- joins, join type, and join predicates;
- every filter column, operator, null test, `IN`/range boundary, and boolean
  grouping; distinguish fixed predicates from caller-controlled predicates;
- `GROUP BY`, `HAVING`, `DISTINCT`, `LIMIT`, `OFFSET`, and lock clauses;
- every `ORDER BY` expression, direction, null placement, and tie-breaker;
- SQL issued by preloads or follow-up `Repo` calls when it is part of the
  operation; and
- whether the operation is a member lookup, collection page, aggregate,
  existence check, update/delete, or worker/maintenance query.

Do not compare literal bind values. If a query is dynamic, record one shape for
each materially different branch (for example, anonymous versus moderator,
`mine` versus all, or a supplied sort versus the default sort).

When source inspection is ambiguous, generate SQL from the Ecto query with
`Ecto.Adapters.SQL.to_sql/3` or exercise the existing targeted test. Run Elixir
through the `app` container as required by `AGENTS.md`; use read-only SQL
inspection and do not change the test or development database. Generated SQL
is supporting evidence, not a substitute for tracing all dynamic branches.

### 3. Classify the delta

For each master/current pair, classify it as one of:

- `unchanged`: same relational shape, possibly moved or reformatted;
- `changed, index-relevant`: filter column/operator, join predicate, ordering,
  grouping/distinct, pagination access path, preload query, or write target
  predicate changed;
- `changed, likely not index-relevant`: selected columns, result mapping, or
  an equivalent predicate representation changed without changing the access
  requirements; or
- `new/deleted/unpaired`: no reliable counterpart exists; explain whether it
  is a moved query, a genuinely new/removed workload, or an audit limitation.

Call out semantic changes that may be correctness issues separately from index
concerns, such as a newly added visibility predicate or a missing parent
scope. Do not turn a possible correctness regression into an index
recommendation.

### 4. Check indexes and evidence

For every index-relevant change, inspect `priv/repo/structure.sql` and the
relevant migration history at both refs. Record existing primary, unique,
partial, expression, GIN/GiST, and ordinary B-tree indexes before proposing a
new one. Check foreign-key indexes for join-heavy queries as well.

An index candidate must state its intended column order and any partial or
specialized form, but it must not be treated as automatic. Use this order of
evidence:

1. an existing index clearly covers the new shape;
2. a representative `EXPLAIN (FORMAT JSON)` or query-plan observation shows a
   plausible missing access path; and
3. workload frequency, table size/cardinality, and predicate selectivity make
   the added write/storage cost worthwhile.

Use equality columns before range columns when considering a composite B-tree,
then account for the requested ordering and tie-breaker. Treat `OR`, leading
wildcard `ILIKE`, array containment, random ordering, aggregates, and complex
fragments as cases requiring specialized analysis; do not recommend a generic
B-tree merely because a column appears in a predicate. Primary-key and
unique-constraint coverage should be marked as covered, not proposed again.

## Per-context report format

Each agent writes a concise report with this structure:

```md
# <Context> SQL shape audit

Refs: master -> context-logic
Status: complete | blocked (with reason)
Query sites inspected: <count>

## Changed shapes

### <operation>

- Master: <file:line and normalized shape>
- context-logic: <file:line and normalized shape>
- Delta: <filters/joins/order/group/pagination/preload/write predicate>
- Index status: covered | candidate | no index action | needs plan evidence
- Evidence: <existing index, explain, or workload reasoning>
- Confidence: high | medium | low

## Unchanged or non-index-relevant sites

<grouped list with enough locations to prove coverage>

## New, deleted, moved, or ambiguous sites

<explanation and counterpart, if any>

## Follow-ups

<correctness issues, shared-query links, or missing runtime evidence>
```

Line numbers are navigation aids only; include stable function names and
operation names so the report remains useful after unrelated edits. Keep large
generated SQL out of the report; include a normalized shape and a short SQL
fragment only when it resolves ambiguity.

## Coordinator synthesis and verification

After all context reports are complete:

1. Compare reports for shared query builders, visibility scopes, preload
   helpers, and cross-context joins. Assign one owner to each duplicate and
   link all consumers to it.
2. Reconcile moved/deleted queries against the complete `git diff
--find-renames`, including old `lib/philomena_web` loaders and API
   controllers. Check that every changed Ecto query site is either classified
   or explicitly listed as ambiguous.
3. Recheck every proposed index against the current `structure.sql`, unique
   constraints, partial-index predicates, and any branch migrations. Merge
   equivalent candidates and separate candidates that serve different query
   branches.
4. Run read-only `EXPLAIN` checks only for the highest-value candidates and
   record the exact representative shape/parameters and limitations. An
   unavailable or unrepresentative local dataset lowers confidence; it does
   not justify inventing a migration.
5. Produce `summary.md` with four sections: confirmed shape changes, index
   candidates ranked by urgency/confidence, covered/no-action changes, and
   unresolved questions. Include the owning context, operation, affected
   table, proposed index definition, evidence, and write-cost caveat for every
   candidate.

The audit is complete when all assignment-matrix contexts have a report,
shared queries have one canonical finding, every master/current query pair is
classified, and the summary contains no index recommendation unsupported by
an identified query shape and schema check.
