# SQL query-shape audit summary

Refs: master -> context-logic  
Status: complete  
Scope: Wave A (20 contexts), Wave B (6 contexts), and Wave C (7 contexts); read-only audit; no application code or migrations changed.

All 26 Wave A/B assignment-matrix contexts have a complete report: [activities](activities.md),
[adverts](adverts.md), [artistlinks](artistlinks.md), [autocomplete](autocomplete.md),
[badges](badges.md), [bans](bans.md), [channels](channels.md), [donations](donations.md),
[modnotes](modnotes.md), [moderationlogs](moderationlogs.md), [notifications](notifications.md),
[roles](roles.md), [rules](rules.md), [sitenotices](sitenotices.md),
[staticpages](staticpages.md), [userfingerprints](userfingerprints.md),
[userips](userips.md), [usernamechanges](usernamechanges.md),
[userstatistics](userstatistics.md), [versions](versions.md), [users](users.md),
[profiles](profiles.md), [conversations](conversations.md), [commissions](commissions.md),
[dnpentries](dnpentries.md), and [reports](reports.md). Shared findings are
canonicalized in [shared.md](shared.md).

All seven Wave C contexts have a complete report: [forums](forums.md),
[topics](topics.md), [posts](posts.md), [comments](comments.md),
[polls](polls.md), [poll options](poll_options.md), and
[poll votes](poll_votes.md).

## Confirmed shape changes

### Wave A

| Context          | Confirmed delta                                                                                                                                                                                         | Index disposition                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Activities       | Homepage channel/topic listings now use context pagination/counts; topic visibility is actor-dependent; interaction/preload ownership moved.                                                            | Existing filter, join, PK, and subscription indexes cover the identified paths.                     |
| Adverts          | Active-date/live predicates were added to click lookup; counter upserts became row-targeted updates; the no-tag random branch lost its former restrictions predicate.                                   | PK/date coverage; no random-order index action. The restrictions change is a correctness follow-up. |
| ArtistLinks      | Tag canonicalization/locking changed; profile lookup adds `deleted_at IS NULL`; artist-link admin branches gain `id DESC` tie-breakers and new state branches.                                          | Existing unique/PK/state indexes cover equality paths; ordered composites need validation.          |
| Autocomplete     | Generator changed from predicate cleanup after insert to predicate-free delete-then-insert.                                                                                                             | No index action for the intended singleton artifact.                                                |
| Badges           | Profile lookup adds active-user filtering; profile award lookup adds `user_id` scope; award workflow moved into a transaction builder.                                                                  | Users slug, award, and PK indexes cover the paths.                                                  |
| Bans             | Effective-ban selection now projects priority/newest metadata; admin listings gain `id DESC`; subnet profile lookup moved into Bans.                                                                    | Existing PK/date/GiST/foreign-key indexes cover the access paths.                                   |
| Channels         | No-search listing removes an unnecessary join in favor of a preload; `cq` matching now has leading-wildcard behavior; alias replacement adds a covered `UPDATE ... WHERE associated_artist_tag_id = ?`. | No generic B-tree action; provider/search candidates require plans.                                 |
| ModNotes         | Target-scoped embedded reads add `LIMIT 250` and explicit target loads; malformed/multiple target parameters can fall back to an unfiltered page.                                                       | Existing partial target indexes cover filters; ordered partial composites need validation.          |
| ModerationLogs   | Retained listing adds `id DESC` after `created_at DESC`.                                                                                                                                                | Existing date index is used; a date/id composite needs workload evidence.                           |
| Notifications    | Unknown category input no longer falls through to a forum-post query.                                                                                                                                   | Deleted invalid-input workload; valid category and clear/fan-out paths remain covered.              |
| Roles            | User lock workflows add role association preloads and a new locked member read.                                                                                                                         | PK and `(user_id, role_id)` coverage; no candidate.                                                 |
| UserFingerprints | History/latest paths gain pagination/count and `id DESC`; current local plan sorts after the existing user-id index.                                                                                    | Strongest validation candidate: `(user_id, updated_at DESC, id DESC)`.                              |
| UserIps          | History/latest paths gain pagination/count and `id DESC`.                                                                                                                                               | Existing `(user_id, updated_at DESC)` is substantially covering; composite requires validation.     |
| UserNameChanges  | Rename history becomes a bounded paginated/count query while retaining `user_id` and `id DESC`.                                                                                                         | Existing user-id index covers filtering; composite requires validation.                             |
| UserStatistics   | New bulk `user_id IN (...)` update and multi-row daily upsert path.                                                                                                                                     | PK/unique keys cover both lookup and conflict target.                                               |
| Versions         | No-op edits now suppress the existing version existence/inserts; meaningful version lookup shape is unchanged.                                                                                          | Existing owner/date indexes cover the retained query.                                               |

The remaining contexts—Donations, Rules, SiteNotices, and StaticPages—report no
SQL shape change in their retained workloads; their moved/member/history paths
are covered in their individual reports.

### Wave B

| Context       | Confirmed delta                                                                                                                                                              | Index disposition                                                                                               |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Users         | Public/profile loads add `deleted_at IS NULL`; alias discovery changes joins to nested `IN` subqueries; erasure adds report-closure selection and wipe ownership delegation. | Slug, PK, user-id, and existing report indexes cover the changed paths; no automatic candidate.                 |
| Profiles      | IP/fingerprint history becomes bounded pagination with `updated_at DESC, id DESC`; profile and source/tag history ownership is composed through contexts.                    | IP ordering prefix is covered; fingerprint ordering is a measured composite candidate below.                    |
| Conversations | Conversation and message pages gain `id` tie-breakers; nested approval adds a conversation-parent predicate.                                                                 | Existing message conversation/time and PK indexes cover equality/leading order; tie-breaker indexes need plans. |
| Commissions   | Directory adds active-user join/filter; commission-item preloads gain `base_price ASC, id ASC` ordering.                                                                     | Existing join indexes cover filters; ordered item preload is a measured candidate below.                        |
| DnpEntries    | Admin text search normally adds the active-state predicate; count expression changes to `COUNT(*)`; query builders move into context.                                        | Existing partial state/FK indexes cover the relational paths; wildcard OR search needs specialized analysis.    |
| Reports       | Moderation transitions add PK row locks; report attribution wipe is a new user-scoped maintenance update; other report queries move unchanged.                               | PK, user/admin/open, and partial target-FK indexes cover all changed paths; no automatic candidate.             |

Correctness follow-ups include the DNP default-state behavior,
active/deleted-user visibility, and nested conversation parent scoping.

### Wave C

| Context     | Confirmed delta                                                                                                                                                                                                     | Index disposition                                                                                                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Forums      | Forum/topic visibility moved into actor-dependent SQL; route workflows now use slug/parent-scoped locks and page/count relations.                                                                                   | Existing slug, topic foreign-key, and primary-key indexes cover the changed lookups; homepage/order paths need plans, with no unsupported candidate.                                            |
| Topics      | Homepage/topic-page queries gain actor-dependent visibility, parent-scoped topic lookup, pagination/count, post availability predicates, and deterministic ordering; last-post refresh gains a timestamp aggregate. | Existing `(forum_id, slug)`, `(topic_id, created_at)`, and foreign-key indexes cover the principal paths; homepage composite needs runtime plan evidence.                                       |
| Posts       | Route post loads gain parent/availability predicates; history gains an ID tie-breaker; last-pointer refresh uses visible-post max aggregates; attribution wipe is user-scoped.                                      | Existing PK, topic/order, version-history, and user indexes cover most paths. A partial `(topic_id, id) WHERE hidden_from_users IS FALSE` candidate is deferred pending plan/workload evidence. |
| Comments    | Image-comment collections/counts gain hidden-comment visibility predicates and deterministic ID tie-breakers; route/history loads are parent-scoped.                                                                | Existing image/time, image, user, version, and PK indexes cover the primary paths; approval/visibility OR branches need evidence before any specialized index.                                  |
| Polls       | Poll loading is topic-scoped with options/topic/forum preloads; updates and vote totals use explicit PK locks/updates; active checks are now in memory.                                                             | Existing topic, option-parent, and PK indexes cover all retained paths; no candidate.                                                                                                           |
| PollOptions | Option preloading and counter updates are centralized; counter writes gain `poll_id` parent scope.                                                                                                                  | Existing `(poll_id, label)` and option PK indexes cover the paths; no candidate.                                                                                                                |
| PollVotes   | Staff listing adds `vote_count > 0`; vote deletion gains poll-parent scoping and a poll lock; existence, insert, and counter transaction shapes remain covered.                                                     | Existing poll/option/vote PK, foreign-key, and unique indexes cover the changed paths; no candidate.                                                                                            |

## Index candidates ranked by urgency/confidence

These are candidates for measured follow-up, not approved migrations. Every
candidate is tied to a changed query shape and an existing schema check; the
local plans are small or absent, so no recommendation is automatic.

1. **Medium / highest validation priority — UserFingerprints history/latest.**
   Candidate: `user_fingerprints (user_id, updated_at DESC, id DESC)`. The
   existing `user_id` index covered filtering but a read-only local
   `EXPLAIN (FORMAT JSON)` for `user_id = 1 ORDER BY updated_at DESC, id DESC
LIMIT 50 OFFSET 0` showed a bitmap scan followed by a sort (estimated five
   rows, total cost 12.73). The local table was 8 KB and effectively tiny;
   validate with production-like cardinality, `EXPLAIN (ANALYZE, BUFFERS)`, and
   request frequency before accepting the write/storage cost.

2. **Medium / validation priority — commission item preloads.** Candidate:
   `commission_items (commission_id, base_price ASC, id ASC)`. A read-only
   local `EXPLAIN (FORMAT JSON)` for `commission_id IN (1, 2)` used
   `index_commission_items_on_commission_id` and then sorted by `base_price, id`
   (estimated four rows, total cost 12.69). The estimate is too small to prove
   benefit; validate with representative directory/profile fan-out, table
   cardinality, and write/storage cost before adding it.

3. **Medium / validation priority — ModerationLogs retained page.** Candidate:
   `moderation_logs (created_at DESC, id DESC)`. The existing `created_at`
   index was used with an incremental sort in a local representative plan;
   the estimate was only 183 retained rows. Measure the actual two-week page
   and count workloads before adding a write-maintained ordering index.

4. **Low-to-medium / shape confidence high — ModNotes target-scoped pages.**
   Candidates, each partial on its existing target predicate:
   `mod_notes (user_id, id DESC) WHERE user_id IS NOT NULL`,
   `mod_notes (report_id, id DESC) WHERE report_id IS NOT NULL`, and
   `mod_notes (dnp_entry_id, id DESC) WHERE dnp_entry_id IS NOT NULL`.
   Existing partial target indexes cover equality filters; no representative
   plan or workload data proves that avoiding the tie-order sort pays for
   three additional indexes.

5. **Low / shape confidence high, candidate confidence low — ArtistLinks
   admin pages.** For the pending-state branch, candidate
   `artist_links (aasm_state, created_at DESC, id DESC)`; for the all-state
   branch, candidate `artist_links (created_at DESC, id DESC)`. A local plan
   used the state index and sorted, but it was unanalyzed and no production
   selectivity/frequency evidence is available.

6. **Low / no plan evidence — Channels provider maintenance.** Candidate
   `channels (type, short_name)` for the `short_name IN (...)` lookup and
   `type = ? AND short_name NOT IN (...)` update. Search branches use OR and
   leading-wildcard `ILIKE`, so they need specialized analysis rather than a
   generic B-tree.

7. **Low / existing order prefix covers — UserIps history.** Candidate
   `user_ips (user_id, updated_at DESC, id DESC)`. The existing
   `(user_id, updated_at DESC)` index covers the principal path; no plan or
   workload evidence justifies the suffix.

8. **Low / bounded history — UserNameChanges history.** Candidate
   `user_name_changes (user_id, id DESC)`. The existing user-id index covers
   the filter and the profile page is capped at 250 rows; measure before
   considering the extra write/storage cost. The related Profiles IP history
   path is already covered by `(user_id, updated_at DESC)` and does not create a
   duplicate candidate.

9. **Low-to-medium / needs plan and workload evidence — post last-pointer
   refresh.** Candidate: partial B-tree
   `posts (topic_id, id) WHERE hidden_from_users IS FALSE` for the visible-post
   `max(id)` branch in the Topics/Forums refresh workflow. The existing
   `(topic_id, created_at)` index covers the timestamp aggregate, but no current
   index directly orders visible posts by topic and ID. This remains a measured
   candidate only; validate both correlated aggregates, table cardinality,
   refresh frequency, and write/storage cost before adding it.

No candidate is proposed for random ordering, leading-wildcard text search,
OR/full-text fragments, conversation participant OR branches without plan
evidence, DNP state/text branches, unchanged version/rule history shapes,
notification fan-out, subscriptions, or primary-key/unique-conflict access
paths.

## Covered/no-action changes

### Wave A

- **Activities, Adverts, ArtistLinks, Badges, Bans, and Channels:** changed
  member, preload, join, containment, subscription, tag, and write-target
  paths are covered by primary, unique, foreign-key, date, state, GiST, or
  association indexes already present in both refs. See [shared.md](shared.md)
  for canonical subscriptions, interactions, visibility, Loader, and tag
  findings.
- **Autocomplete:** the singleton artifact table has no useful missing access
  path; unchanged tag aggregate/random/HAVING workloads are not generic B-tree
  candidates.
- **Donations, Roles, Rules, SiteNotices, and StaticPages:** retained SQL is
  unchanged or moved only, with existing slug/name/position, PK, date, and
  foreign-key coverage where applicable.
- **ModNotes, ModerationLogs, UserFingerprints, UserIps, and
  UserNameChanges:** existing equality/filter indexes cover the changed
  predicates; only the optional ordering suffixes remain for measured follow-up.
- **Notifications:** per-user/date indexes, event-FK indexes, and conflict
  indexes cover category reads, fan-out, clears, and image notification
  migration.
- **UserStatistics and Versions:** primary/unique owner/date keys cover the
  new bulk upsert or retained version existence/history shapes.

### Wave B

- **Users, Profiles, Conversations, Commissions, DnpEntries, and Reports:**
  Member loads, visibility predicates, participant/unread/count
  queries, report-target operations, and maintenance writes are covered by
  existing primary, unique, foreign-key, partial-state, and user/date indexes.
  The only candidate retained for measured follow-up is the ordered
  commission-item preload; the fingerprint candidate is shared with the
  existing UserFingerprints finding above.

### Wave C

- **Forums, Topics, Posts, and Comments:** hierarchy member loads, route
  scoping, visibility branches, association preloads, history queries, and
  transaction locks are covered by existing primary, unique, foreign-key,
  image/time, version-history, and user indexes. The post last-pointer
  candidate above is the only Wave C candidate retained for measurement.
- **Polls, PollOptions, and PollVotes:** topic/option/vote loads, existence
  checks, staff listings, row locks, counter updates, and uniqueness targets
  are covered by existing primary, topic/parent, foreign-key, and unique
  indexes; no poll index candidate is proposed.

## Unresolved questions

### Wave A

- Confirm whether staff should see the broader forum/topic visibility used by
  the current homepage; this is a correctness question, not an index action.
- Confirm the intentional Adverts no-tag restriction change and the intended
  priority semantics of effective bans.
- Verify whether Channels `like_sanitize/1` intentionally converts prefix
  matching into leading-wildcard contains matching.
- Decide whether the new fixed-size homepage/profile/history uses of
  `Repo.paginate` need count queries; count additions are workload changes but
  not index evidence by themselves.
- Review pagination determinism where unchanged lists still lack a unique
  tie-breaker, including notification/category and donation histories.
- Validate Autocomplete generator single-flight behavior: delete-then-insert
  does not itself enforce one current row.
- Keep shared Loader, Multi locks, subscriptions, visibility, interactions,
  notification clearing, and moderation-log writes linked to their canonical
  findings instead of adding duplicate candidates.
- Runtime evidence is limited: several reports intentionally did not run
  `EXPLAIN`; the fingerprint and commission-item checks used local literal
  parameters (`user_id = 1`, `commission_id IN (1, 2)`) and tiny estimates
  (about 5 and 4 rows) and therefore do not establish production benefit.
  No migration should be created until representative plans, table sizes,
  selectivity, frequency, and write-cost estimates are available.

### Wave B

- Confirm whether the DnpEntries admin form/controller preserves the intended
  explicit state selection; the current default may exclude listed/closed
  entries from text searches.
- Confirm that active/deleted-user filters in profile and commission loads are
  intentional visibility behavior, and that nested conversation approval must
  reject a message outside the route conversation.

### Wave C

- Confirm whether the broader staff forum/topic visibility branches and the
  homepage/forum aggregate behavior are intentional; these are correctness
  questions, not automatic index actions.
- Confirm the intentional API/topic-page ordering change from topic position to
  `created_at, id`, and validate topic-page availability OR predicates and
  homepage pagination/count with representative PostgreSQL plans.
- Validate the visible-post last-pointer refresh candidate with production-like
  cardinality, refresh frequency, both `max(id)` and `max(created_at)` branches,
  and write/storage cost. Do not add a migration from source evidence alone.
- Confirm that comment hidden/approval visibility and poll staff `vote_count`
  filtering are intended behavior; their current low-cardinality/OR predicates
  do not support generic index recommendations.
- No Wave C EXPLAIN was collected because the available Docker/database runtime
  was unavailable or lacked representative data; this lowers confidence in
  optional ordering candidates but does not block the source/schema audit.
