# SQL query-shape audit summary

Refs: master -> context-logic  
Status: complete  
Scope: Wave A (20 contexts), Wave B (6 contexts), Wave C (7 contexts), Wave D (7 contexts), and Wave E (6 contexts); read-only audit; no application code or migrations changed.

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

All seven Wave D contexts have a complete report: [images](images.md),
[image faves](image_faves.md), [image features](image_features.md),
[image hides](image_hides.md), [image intensities](image_intensities.md),
[image votes](image_votes.md), and [interactions](interactions.md).

All six Wave E contexts have a complete report: [galleries](galleries.md),
[duplicate reports](duplicate_reports.md), [filters](filters.md), [tags](tags.md),
[tag changes](tag_changes.md), and [source changes](source_changes.md).

## Confirmed shape changes

### Wave A

| Context          | Confirmed delta                                                                                                                                                                                         | Index disposition                                                                                                                                                   |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Activities       | Homepage channel/topic listings now use context pagination/counts; topic visibility is actor-dependent; interaction/preload ownership moved.                                                            | Existing filter, join, PK, and subscription indexes cover the identified paths.                                                                                     |
| Adverts          | Active-date/live predicates were added to click lookup; counter upserts became row-targeted updates; the no-tag random branch lost its former restrictions predicate.                                   | PK/date coverage; no random-order index action. The restrictions change is a correctness follow-up.                                                                 |
| ArtistLinks      | Tag canonicalization/locking changed; profile lookup adds `deleted_at IS NULL`; artist-link admin branches gain `id DESC` tie-breakers and new state branches.                                          | Existing unique/PK/state indexes cover equality paths; ordered composites need validation.                                                                          |
| Autocomplete     | Generator changed from predicate cleanup after insert to predicate-free delete-then-insert.                                                                                                             | No index action for the intended singleton artifact.                                                                                                                |
| Badges           | Profile lookup adds active-user filtering; profile award lookup adds `user_id` scope; award workflow moved into a transaction builder.                                                                  | Users slug, award, and PK indexes cover the paths.                                                                                                                  |
| Bans             | Effective-ban selection now projects priority/newest metadata; admin listings gain `id DESC`; subnet profile lookup moved into Bans.                                                                    | Existing PK/date/GiST/foreign-key indexes cover the access paths.                                                                                                   |
| Channels         | No-search listing removes an unnecessary join in favor of a preload; `cq` matching now has leading-wildcard behavior; alias replacement adds a covered `UPDATE ... WHERE associated_artist_tag_id = ?`. | No generic B-tree action; provider/search candidates require plans.                                                                                                 |
| ModNotes         | Target-scoped embedded reads add `LIMIT 250` and explicit target loads; malformed/multiple target parameters can fall back to an unfiltered page.                                                       | Existing partial target indexes cover filters; ordered partial composites need validation.                                                                          |
| ModerationLogs   | Retained listing adds `id DESC` after `created_at DESC`.                                                                                                                                                | Existing date index is used; a date/id composite needs workload evidence.                                                                                           |
| Notifications    | Unknown category input no longer falls through to a forum-post query.                                                                                                                                   | Deleted invalid-input workload; valid category and clear/fan-out paths remain covered.                                                                              |
| Roles            | User lock workflows add role association preloads and a new locked member read.                                                                                                                         | PK and `(user_id, role_id)` coverage; no candidate.                                                                                                                 |
| UserFingerprints | History/latest paths gain pagination/count and `id DESC`; local plan sorts after the existing user-id index, and production review reports request timeouts.                                            | Confirmed follow-up: `(user_id, updated_at DESC, id DESC)`; capture production plan/size/build evidence during migration review.                                    |
| UserIps          | History/latest paths gain pagination/count and `id DESC`.                                                                                                                                               | Confirmed follow-up: replace `(user_id, updated_at DESC)` with `(user_id, updated_at DESC, id DESC)`; verify no other query needs the old index before dropping it. |
| UserNameChanges  | Rename history becomes a bounded paginated/count query while retaining `user_id` and `id DESC`.                                                                                                         | Existing user-id index covers filtering; composite requires validation.                                                                                             |
| UserStatistics   | New bulk `user_id IN (...)` update and multi-row daily upsert path.                                                                                                                                     | PK/unique keys cover both lookup and conflict target.                                                                                                               |
| Versions         | No-op edits now suppress the existing version existence/inserts; meaningful version lookup shape is unchanged.                                                                                          | Existing owner/date indexes cover the retained query.                                                                                                               |

The remaining contexts—Donations, Rules, SiteNotices, and StaticPages—report no
SQL shape change in their retained workloads; their moved/member/history paths
are covered in their individual reports.

### Wave B

| Context       | Confirmed delta                                                                                                                                                              | Index disposition                                                                                                       |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| Users         | Public/profile loads add `deleted_at IS NULL`; alias discovery changes joins to nested `IN` subqueries; erasure adds report-closure selection and wipe ownership delegation. | Slug, PK, user-id, and existing report indexes cover the changed paths; no automatic candidate.                         |
| Profiles      | IP/fingerprint history becomes bounded pagination with `updated_at DESC, id DESC`; profile and source/tag history ownership is composed through contexts.                    | Fingerprint ordering is covered by the confirmed UserFingerprints follow-up; IP uses the confirmed UserIps replacement. |
| Conversations | Conversation and message pages gain `id` tie-breakers; nested approval adds a conversation-parent predicate.                                                                 | Existing message conversation/time and PK indexes cover equality/leading order; tie-breaker indexes need plans.         |
| Commissions   | Directory adds active-user join/filter; commission-item preloads gain `base_price ASC, id ASC` ordering.                                                                     | Existing join indexes cover filters; ordered item preload is rejected at reviewed p99 cardinality.                      |
| DnpEntries    | Admin text search normally adds the active-state predicate; count expression changes to `COUNT(*)`; query builders move into context.                                        | Existing partial state/FK indexes cover the relational paths; wildcard OR search needs specialized analysis.            |
| Reports       | Moderation transitions add PK row locks; report attribution wipe is a new user-scoped maintenance update; other report queries move unchanged.                               | PK, user/admin/open, and partial target-FK indexes cover all changed paths; no automatic candidate.                     |

Correctness follow-ups include the DNP default-state behavior,
active/deleted-user visibility, and nested conversation parent scoping.

### Wave C

| Context     | Confirmed delta                                                                                                                                                                                                     | Index disposition                                                                                                                                                                                                                                               |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Forums      | Forum/topic visibility moved into actor-dependent SQL; route workflows now use slug/parent-scoped locks and page/count relations.                                                                                   | Existing slug, topic foreign-key, and primary-key indexes cover the changed lookups; homepage/order paths need plans, with no unsupported candidate.                                                                                                            |
| Topics      | Homepage/topic-page queries gain actor-dependent visibility, parent-scoped topic lookup, pagination/count, post availability predicates, and deterministic ordering; last-post refresh gains a timestamp aggregate. | Existing `(forum_id, slug)`, `(topic_id, created_at)`, and foreign-key indexes cover principal paths. Partial `(topic_id, id) WHERE hidden_from_users IS FALSE` is a confirmed follow-up for last-pointer refresh; topic-page ordering needs a correctness fix. |
| Posts       | Route post loads gain parent/availability predicates; history gains an ID tie-breaker; last-pointer refresh uses visible-post max aggregates; attribution wipe is user-scoped.                                      | Existing PK, topic/order, version-history, and user indexes cover most paths. The partial `(topic_id, id) WHERE hidden_from_users IS FALSE` index is a confirmed follow-up.                                                                                     |
| Comments    | Image-comment collections/counts gain hidden-comment visibility predicates and deterministic ID tie-breakers; route/history loads are parent-scoped.                                                                | Existing image/time, image, user, version, and PK indexes cover the primary paths; approval/visibility OR branches need evidence before any specialized index.                                                                                                  |
| Polls       | Poll loading is topic-scoped with options/topic/forum preloads; updates and vote totals use explicit PK locks/updates; active checks are now in memory.                                                             | Existing topic, option-parent, and PK indexes cover all retained paths; no candidate.                                                                                                                                                                           |
| PollOptions | Option preloading and counter updates are centralized; counter writes gain `poll_id` parent scope.                                                                                                                  | Existing `(poll_id, label)` and option PK indexes cover the paths; no candidate.                                                                                                                                                                                |
| PollVotes   | Staff listing adds `vote_count > 0`; vote deletion gains poll-parent scoping and a poll lock; existence, insert, and counter transaction shapes remain covered.                                                     | Existing poll/option/vote PK, foreign-key, and unique indexes cover the changed paths; no candidate.                                                                                                                                                            |

### Wave D

| Context          | Confirmed delta                                                                                                                                                                                     | Index disposition                                                                                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Images           | Image workflows consolidate member/lock/preload paths; featured selection consistently applies hidden-image and viewer-hide predicates; batch maintenance adds an explicit visible-image predicate. | Existing image PK, approval partial, feature created-at/image, child foreign-key, and interaction indexes cover the paths. No automatic candidate.                        |
| ImageFaves       | Create now deletes an existing `(image_id,user_id)` row before insert; user cleanup is context-owned batch deletion; merge inserts add `RETURNING user_id`.                                         | Existing unique `(image_id,user_id)` and `user_id` indexes cover deletes, conflict checks, preloads, and cleanup. No candidate.                                           |
| ImageFeatures    | Featured-image query moved/consolidated into Images; API now excludes the caller's hidden images; feature creation adds an image PK load and lock.                                                  | Existing feature created-at/image indexes, image PK, and hide unique index cover all paths. No candidate.                                                                 |
| ImageHides       | Hide replacement/deletion and merge/preload/export operations retain their image/user predicates; ownership moved into loaded-image transaction steps.                                              | Existing unique `(image_id,user_id)` and `user_id` indexes cover all changed/moved paths. No candidate.                                                                   |
| ImageIntensities | Intensity persistence changed from plain insert to `ON CONFLICT (image_id) DO UPDATE`; CRUD surface was removed; image-delete FK now cascades.                                                      | Existing unique `image_intensities(image_id)` is the upsert arbiter; cascade is referential only. No candidate.                                                           |
| ImageVotes       | Vote replacement adds per-direction deletes; user cleanup is context-owned batched deletion; merge inserts return inserted user IDs.                                                                | Production review confirms a cleanup index follow-up: `(user_id, image_id)` replacing standalone `user_id`; `up` remains a residual predicate and should be plan-checked. |
| Interactions     | Actor-first interaction API and empty-input short-circuit preserve the four-branch `UNION ALL`; merge transaction ownership and `RETURNING` changed only composition/materialization.               | Existing interaction unique/user indexes and image PK cover all paths. No candidate.                                                                                      |

### Wave E

| Context          | Confirmed delta                                                                                                                                                                                             | Index disposition                                                                                                                                       |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Galleries        | Add/remove/delete/reorder workflows now lock image/gallery rows, batch interaction cleanup, and use deterministic membership ordering; a new owner gallery selector orders by `updated_at`.                 | Existing gallery/image PKs, gallery-interaction unique/FK/order indexes, and partial report-gallery index cover paths; no candidate without plans.      |
| DuplicateReports | Perceptual matching adds deterministic image-ID tie-breaking and actor-dependent hidden-image filtering; report pages gain `id DESC`; reverse acceptance adds latest-row ordering and active-state scoping. | Intensity/image/report state and direction indexes cover principal paths. Reverse-pair composite was reviewed and rejected at observed p99 cardinality. |
| Filters          | Owner/system pages gain deterministic ordering and pagination; recent/own selection changes limits/order; tag replacement is a moved array-containment workload.                                            | User/system indexes cover filters; owner ordering is low-volume and array replacement should be normalized into an indexed join table.                  |
| Tags             | Canonicalization and alias/deletion workflows add ordered PK locks, slug lookups, and batched tag/image cleanup; implication repair is context-owned.                                                       | Existing tag name/slug/PK, alias/implication, tagging, and dependent FK indexes cover all changed paths; no candidate.                                  |
| TagChanges       | Tag-change writes/reverts are batch-oriented; selected-ID reversion adds an `id DESC` tie-breaker; attribution cleanup is context-owned.                                                                    | Existing image/user/fingerprint/IP and join-table indexes cover selectors and preloads; no candidate.                                                   |
| SourceChanges    | Image/user/IP/fingerprint history pages order by `created_at DESC, id DESC` and support an `added` branch; user distinct counts explicitly drop page ordering.                                              | Existing image/user/IP/PK indexes cover filters; infrequent fingerprint history is intentionally deferred to possible OpenSearch migration.             |

## Index candidates ranked by urgency/confidence

These are candidates for measured follow-up, not approved migrations. Every
candidate is tied to a changed query shape and an existing schema check; the
local plans are small or absent, so no recommendation is automatic.

1. **High / confirmed follow-up — UserFingerprints history/latest.** Candidate:
   `user_fingerprints (user_id, updated_at DESC, id DESC)`. The existing
   `user_id` index covered filtering but a read-only local `EXPLAIN (FORMAT JSON)`
   for `user_id = 1 ORDER BY updated_at DESC, id DESC LIMIT 50 OFFSET 0`
   showed a bitmap scan followed by a sort (estimated five rows, total cost
   12.73). The focused production review reports request timeouts on current
   `master` deployments and confirms this follow-up. The local table was 8 KB
   and effectively tiny; capture production-sized plans, index size, and
   build/write cost during migration review.

2. **Medium / confirmed follow-up — UserIps history.** Replace
   `user_ips (user_id, updated_at DESC)` with
   `user_ips (user_id, updated_at DESC, id DESC)`. The new index retains the
   old index as an exact prefix and supports deterministic history order;
   verify repository-wide usage, index size, and safe drop timing before
   removing the old index.

3. **Medium / confirmed follow-up — post last-pointer refresh.** Candidate:
   partial B-tree
   `posts (topic_id, id) WHERE hidden_from_users IS FALSE` for the visible-post
   `max(id)` branch in the Topics/Forums refresh workflow. The existing
   `(topic_id, created_at)` index covers the timestamp aggregate, but no current
   index directly orders visible posts by topic and ID. The focused production
   review confirms this index for the repeated max-ID branch; capture
   production-sized plans and write/storage cost during migration review and
   reconcile it with the max(created_at) branch.

4. **Medium / confirmed follow-up — ImageVotes user cleanup.** Candidate:
   `image_votes (user_id, image_id)` replacing `index_image_votes_on_user_id`.
   This preserves user equality and image-ID batch ordering while leaving
   `up` as a residual direction predicate. The focused production review
   confirms the workload need; compare this two-column shape with the
   three-column `(user_id, up, image_id)` alternative using representative
   plans, then account for index size and write/storage cost before migration.

### Reviewed and rejected candidates

- Commission-item, ModerationLogs, ModNotes, ArtistLinks, Channels,
  UserNameChanges, DuplicateReports reverse-pair, Filters owner-ordering, and
  SourceChanges fingerprint/history composites are not recommended. The
  focused review cites low p99 cardinality, infrequent workloads, existing
  order prefixes, or a future OpenSearch/association-normalization path.
- These rejected ideas remain documented in the owning reports for traceability;
  they are not migration candidates.

No candidate is proposed for random ordering, leading-wildcard text search,
OR/full-text fragments, conversation participant OR branches without plan
evidence, DNP state/text branches, unchanged version/rule history shapes,
notification fan-out, subscriptions, or primary-key/unique-conflict access
paths. Gallery owner selection and reordered `IN` scans, tag-change batch
reverts, DuplicateReports reverse-pair lookup, Filters owner ordering, filter
array replacement (moved unchanged), tag canonicalization/cleanup, and tag
aggregate/random workloads are covered, low-volume, or unchanged; they do not
add candidates beyond the confirmed/measurement items above. Wave D image
member, featured, interaction, hide/fave/vote, feature, intensity, and preload
changes are covered; ImageVotes cleanup is the confirmed Wave D follow-up.

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
- **ModNotes, ModerationLogs, and UserNameChanges:** existing equality/filter
  indexes cover the changed predicates; optional ordering suffixes remain
  measured follow-ups. UserFingerprints and UserIps are confirmed index
  follow-ups listed above.
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
  The ordered commission-item preload remains measurement-only; the
  fingerprint candidate is a confirmed follow-up owned by UserFingerprints.

### Wave C

- **Forums, Topics, Posts, and Comments:** hierarchy member loads, route
  scoping, visibility branches, association preloads, history queries, and
  transaction locks are covered by existing primary, unique, foreign-key,
  image/time, version-history, and user indexes. The partial post last-pointer
  index is a confirmed follow-up; topic-page ordering remains a correctness
  fix rather than an index action.
- **Polls, PollOptions, and PollVotes:** topic/option/vote loads, existence
  checks, staff listings, row locks, counter updates, and uniqueness targets
  are covered by existing primary, topic/parent, foreign-key, and unique
  indexes; no poll index candidate is proposed.

### Wave D

- **Images:** member/lock loads, approval queues/counts, featured joins and
  viewer-hide checks, lateral image-show aggregates, interaction preloads, and
  image-child maintenance are covered by existing PK, partial approval,
  feature, foreign-key, and interaction indexes. Hidden-image predicates are
  correctness/visibility changes, not automatic index actions.
- **ImageFaves, ImageHides, and ImageVotes:** per-image
  replacement/deletion, merge conflict inserts, interaction branches, and
  user cleanup batches are covered by existing unique pair and user-ID
  indexes. ImageVotes' user-cleanup replacement index is a confirmed
  follow-up; compare its residual `up` filtering with the three-column
  alternative during migration review.
- **ImageFeatures and ImageIntensities:** feature selection/creation and
  intensity upsert/preload paths are covered by feature created-at/image,
  image PK, hide pair, and intensity image-ID indexes. The intensity cascade
  migration changes delete semantics only.
- **Interactions:** UNION interaction fan-out, source association preloads,
  merge inserts, and image counter updates retain covered access paths; no
  additional shared candidate is proposed.

### Wave E

- **Galleries:** member loads, image add/remove, batched deletion, reorder
  locks/upserts, owner selection, report closure, and moved image-interaction
  maintenance use existing primary, unique, foreign-key, position, and
  partial report-gallery indexes. No automatic candidate is supported.
- **DuplicateReports:** intensity range joins, report state pages/counts,
  image-pair OR branches, hide-image rejection, and transaction locks are
  covered by existing intensity, image-direction, state/partial-state, FK,
  and primary-key indexes. Reverse latest-row ordering was reviewed and is
  not worth an additional index at the observed p99 pair cardinality.
- **Filters:** default/system/owner lookups, tag preloads, member loads, and
  worker `IN` lookups are covered by existing system/user/name/PK indexes.
  Owner ordering is not worth an index at the observed p99 per-user count;
  tag-array replacement is an unchanged moved workload pending association
  normalization and join-table indexing.
- **Tags:** canonical name/slug lookup, implication and alias traversal,
  batched tagging cleanup, counter locks, and maintenance deletes are covered
  by existing unique, PK, FK, and tag-ID indexes; unchanged array/random and
  `images_count` scans are outside the delta.
- **TagChanges:** image/user/IP/fingerprint selectors, association
  preloads, empty-history anti-joins, and batch writes/reverts are covered by
  existing image/user/GiST/PK and join-table indexes; no candidate.
- **SourceChanges:** image/user history, distinct-image counts, IP range
  lookups, fingerprint loads, source-count laterals, attribution wipes, and
  primary-key deletes retain existing index coverage. Ordering/fingerprint
  composites are intentionally deferred in favor of possible OpenSearch
  migration for the infrequent moderation path.

## Unresolved questions

### Wave A

- Staff visibility rules are intended to apply on the homepage and forum/topic
  paths; retain authorization coverage tests. This is not an index action.
- Adverts' inactive-click exclusion and effective-ban priority semantics are
  intentional; retain regression coverage.
- Channels `like_sanitize/1` had an unintended leading/trailing-wildcard
  change; the focused review says it is fixed (and the Commissions helper was
  aligned). Keep a regression test rather than an index action.
- Homepage channel/topic strips must not issue count queries for their fixed
  six-item display; remove the unnecessary `Repo.paginate` count path before
  merge. This is a workload/API issue, not an index recommendation.
- Review pagination determinism where unchanged lists still lack a unique
  tie-breaker, including notification/category and donation histories.
- Validate Autocomplete generator single-flight behavior: delete-then-insert
  does not itself enforce one current row.
- Keep shared Loader, Multi locks, subscriptions, visibility, interactions,
  notification clearing, and moderation-log writes linked to their canonical
  findings instead of adding duplicate candidates.
- Runtime evidence is limited: several reports intentionally did not run
  `EXPLAIN`; the local fingerprint and commission-item checks used literal
  parameters (`user_id = 1`, `commission_id IN (1, 2)`) and tiny estimates
  (about 5 and 4 rows). The focused production review independently confirms
  the fingerprint follow-up; all other unmeasured candidates remain subject to
  representative plans, table sizes, selectivity, frequency, and write-cost
  checks before migration.

### Wave B

- Add the missing DNP admin “All Entries” display link before merge and confirm
  the form/controller preserves the intended explicit state selection; the
  current default may exclude listed/closed entries from text searches.
- Confirm that active/deleted-user filters in profile and commission loads are
  intentional visibility behavior, and that nested conversation approval must
  reject a message outside the route conversation.

### Wave C

- Staff forum/topic visibility expansion is intentional; retain authorization
  tests. The remaining topic-page ordering policy is addressed below and is a
  correctness fix, not an index action.
- Forum topic listings must continue excluding `hidden_from_users` topics,
  including under the reviewed staff visibility policy; fix the current
  `visible_topics/2` branch before merge. This is a correctness policy, not an
  index recommendation.
- Topic-page posts are bounded by `topic_position` and must be ordered
  ascending by `topic_position`; fix the current `created_at, id` ordering
  before merge. Validate availability OR predicates separately.
- The visible-post last-pointer partial index is a confirmed follow-up from
  production review. Reconcile both `max(id)` and `max(created_at)` branches
  and capture build/write-cost evidence during migration review.
- Confirm that comment hidden/approval visibility and poll staff `vote_count`
  filtering are intended behavior; their current low-cardinality/OR predicates
  do not support generic index recommendations.
- No Wave C EXPLAIN was collected because the available Docker/database runtime
  was unavailable or lacked representative data; this lowers local-plan
  confidence, while the last-pointer index decision comes from the focused
  production review.

### Wave D

- The API's consistent viewer-hide predicate for featured images is intentional
  and should retain regression coverage; it is not an index action.
- ImageVotes cleanup indexing is confirmed by production review. Compare the
  requested `(user_id, image_id)` replacement with the three-column
  `(user_id, up, image_id)` alternative using representative plans, then
  capture index size, build timing, and write/storage cost before migration.
- Batch tag/revert paths intentionally process hidden images while keeping
  visible-image counters accurate; retain regression coverage. Intensity upsert
  and image-delete cascade semantics should likewise retain tests.
- No Wave D EXPLAIN was required for covered PK/unique/FK paths; local runtime
  data was not representative enough to justify optional image composites.

### Wave E

- Galleries' existing per-image/gallery indexes are sufficient for the current
  production workload; no additional index is expected.
- DuplicateReports must allow automated reports against hidden targets when
  intended, while preserving actor authorization. Review the current
  `generate_reports/1` `hidden_from_users = false` predicate before merge.
  Per-image report listings should retain all candidate reports even when a
  viewer cannot see a hidden endpoint; current SQL has no endpoint visibility
  predicate and the template iterates every returned report. Add a regression
  test for this policy rather than an index.
- Confirm Filters' recent/own result cardinality change and whether moving
  member visibility into application authorization preserves intended access.
  Treat array replacement as an unchanged moved workload; normalize the
  association into a join table and index that relation rather than adding
  speculative array GIN indexes.
- Tags' slug-based route semantics and visibility/locking changes are
  intentional; retain regression coverage. Existing implication/alias/tagging
  indexes cover the changed paths.
- TagChanges batch-row semantics and hidden-image reversion behavior are
  intentional; no index gap was found.
- SourceChanges timestamp ordering and normalized identity inputs are
  intentional. The fingerprint equality path has no index, but this infrequent
  moderation path is intentionally deferred in favor of possible OpenSearch
  migration.
- No Wave E EXPLAIN was run against a representative production-sized
  dataset. Conditional candidates not confirmed by the focused production
  review remain evidence-gathering tasks, not migration instructions.
