# Shared SQL shape audit

Refs: master -> context-logic
Status: complete
Scope: Wave A, Wave B, Wave C, Wave D, and Wave E; read-only audit; no application code or migrations changed.

This report owns query shapes shared by contexts across all completed waves,
plus the shared Loader, authorization, visibility, subscription, interaction,
and transaction helpers. Individual context reports link here rather than
duplicating these findings.

## Canonical shared findings

### Loader and authorization

`Philomena.Loader.fetch/3` issues a primary-key `Repo.get`; `one/1` issues a
caller-supplied `Repo.one`; and the authorized variants run the same query
before an in-memory Canada authorization check. `preload` modifiers remain
caller-owned. The helper centralizes moved member loads from controllers and
does not add a SQL predicate for authorization. Primary-key and caller-owned
unique indexes cover these shapes. Consumers include Activities, Adverts,
ArtistLinks, Badges, Bans, Channels, ModNotes, Rules, SiteNotices, and
StaticPages, with additional links from UserFingerprints/UserIps and the
profile-facing contexts.

`Philomena.Authorization.authorize/3` and `verify_write_access/1` are
application-level checks. They issue no SQL and therefore produce no index
candidate. Any newly observed visibility or authorization behavior is recorded
as a correctness follow-up in the owning context report.

### Subscriptions

`Philomena.Subscriptions` owns the same generic shapes used by Channels,
Images, Forums, Topics, and Galleries:

- existence: `<subscription> WHERE <object_id> = ? AND user_id = ?`;
- fan-out: `<object_id> IN (?) AND user_id = ?`;
- insert with the subscription unique key as the `ON CONFLICT` target; and
- delete: `<object_id> = ? AND user_id = ?`.

The current `Philomena.Multi` wrapper changes transaction composition, not
these predicates. Unique `(object_id, user_id)` indexes and user-side indexes
already cover the shapes. No subscription index candidate is recommended.

### Interaction fan-out

`Philomena.Interactions.user_interactions/2` builds four `UNION ALL` branches
over `image_hides`, `image_faves`, and up/down `image_votes`, each constrained
by `image_id IN (...)` and `user_id = ?`; vote branches also constrain `up`.
The Actor-based API and empty-input short-circuit do not change the non-empty
SQL shape. Existing unique `(image_id, user_id)` indexes cover all branches.
This is one canonical finding for Activities and the interaction consumers;
no index action is needed.

### Forum/topic visibility

`Philomena.Forums.Visibility.visible_forums/2` is used by the Activities
homepage topic strip and topic-facing context operations. In
`context-logic`, the topic query joins a visible-forums subquery and applies
actor-dependent access-level predicates; ordinary actors retain the public
forum scope, while assistant/staff branches are broader. Topic visibility
also omits the hidden-topic predicate for staff. This is a real filter/join
shape change and a possible correctness issue, not an automatic index
recommendation. Existing `topics(forum_id)`, `topics(hidden_from_users)`,
`topics(last_replied_to_at)`, and `forums(id)` coverage is retained. A
composite or partial ordered index requires representative plans and
selectivity data. The focused review distinguishes direct staff actions from
collection policy: forum topic listings must still exclude hidden topics even
if staff may load them for authorized direct operations.

### Tags canonicalization and locking

ArtistLinks and Channels now consume the shared tag canonicalization flow.
The flow changes a single-name equality lookup into a `tags.name IN (...)`
lookup with implication/alias preloads, followed by a `tags.id IN (...) ORDER
BY id FOR UPDATE` lock query. The unique `tags(name)` index covers the lookup
and `tags_pkey` covers the lock; association foreign-key indexes cover the
preloads. The shape and locking behavior are canonical here, while tag-specific
search/aggregate workloads remain owned by Tags/Autocomplete consumers.

### Philomena.Multi locking and shared writes

`Philomena.Multi` is a transaction wrapper and does not emit SQL merely by
wrapping ordinary Ecto operations. Its shared lock helpers do add explicit
queries: `lock_one/3` and `lock_all/3` append `FOR UPDATE`,
`lock_advisory/3` executes `pg_advisory_xact_lock`, and serializable
transactions execute `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE`.
These are lock semantics over caller-supplied relations, not independent
lookup shapes; the owning context reports record the relevant query and index
coverage.

`Philomena.ModerationLogs.put_log/*` is called from many contexts but inserts a
log row without a row-selection predicate or conflict target. The retained
moderation-log listing adds only its own `id DESC` tie-breaker, covered in the
ModerationLogs report. No shared log-write index candidate exists.

### Notification clearing

Channel, gallery, image, topic, and post operations share notification clear
helpers whose deletes constrain the event key and `user_id`. The current
ownership and function names changed, but the relevant predicates and existing
event/user indexes remain covered. Notification category reads and fan-out
inserts are canonically summarized in `notifications.md`; no shared index
candidate remains.

### Profile loading and account visibility

`Users.load_profile/2-3` is the canonical profile locator used by Profiles,
Commissions, and report/profile-facing controller paths. Its relational shape
is `users WHERE slug = ? AND deleted_at IS NULL`, followed by caller-selected
association preloads. `index_users_on_slug` covers the lookup; the added
`deleted_at` predicate does not justify a second index because the lookup is
already selective on the unique slug. The predicate is a semantic visibility
change and should be reviewed separately from index concerns. Generic
`Loader.fetch_and_authorize` member loads remain primary-key covered and do not
add SQL authorization predicates.

### Profile history pagination

Profiles composes the canonical `UserIps.load_user_history/3` and
`UserFingerprints.load_user_history/3` operations. Both now page a user-scoped
history with `ORDER BY updated_at DESC, id DESC`; the IP path is covered by
`(user_id, updated_at DESC)`, while the fingerprint path is a confirmed
follow-up for `(user_id, updated_at DESC, id DESC)`. The same composite is one
deduplicated candidate owned by UserFingerprints; Profiles is a consumer and
does not produce a second candidate. The focused review also confirms replacing
the IP two-column index with the three-column form so the deterministic tie
breaker is covered.

### Cross-context report closure and wipe

`Reports.put_close_reports/4` is the canonical dynamic-target update used by
Conversations, Commissions, DnpEntries, and other reportable contexts:
`UPDATE reports ... WHERE <target_fk> = ? AND open = true`. The existing
partial target-FK indexes cover the valid branches; the shared `open` residual
predicate has no automatic composite-index recommendation. `Users.UserWipe`
delegates attribution updates/deletes to owning contexts, so each table's
`user_id` selection remains owned by that context; shared review should link to
the Users and Reports reports rather than duplicate those write shapes.

### Shared profile history and association consumers

The Profiles report delegates source, tag, moderation-note, IP, and fingerprint
history queries to SourceChanges, TagChanges, ModNotes, UserIps, and
UserFingerprints. Those consumers retain ownership of their SQL shapes. The
delegated profile wrappers add no independent predicates or index candidates.

### Wave C forum hierarchy, visibility, and locking

The Wave C forum hierarchy is shared by Forums, Topics, Posts, and Comments.
The canonical route chain is a forum lookup by unique `short_name`, a topic
lookup by `(forum_id, slug)`, and a post/comment lookup by primary key plus
the appropriate parent scope. `Forums.TransactionWorkflow` composes explicit
`FOR UPDATE` locks over the forum/topic/post rows; its `EXISTS` parent checks
use the existing hierarchy primary, foreign-key, and unique indexes. The
workflow's last-post refreshes add correlated `max(id)`/`max(created_at)`
scans over visible posts. The existing `(topic_id, created_at)` index covers
the timestamp branch; the focused production review confirms a partial
`(topic_id, id) WHERE hidden_from_users IS FALSE` follow-up for the repeated
max-ID branch. Reconcile it with the timestamp branch and capture build/write
cost during migration review.

`Forums.Visibility`, `Topics.Visibility`, `Posts.Visibility`, and
`Comments.Visibility` produce actor-dependent SQL branches. These visibility
predicates are genuine shape and correctness changes when moved from
controllers into context queries, but low-cardinality booleans, `OR`
branches, and role-dependent subqueries do not justify generic indexes from
source inspection. The homepage/forum/topic collection ordering questions
remain linked to the Topics and Forums reports; no duplicate shared candidate
is created.

### Wave C poll aggregate and vote persistence

Polls, PollOptions, and PollVotes share the canonical poll chain:
`polls WHERE topic_id = ?`, `poll_options WHERE poll_id IN (?)`, and
`poll_votes` joined through `poll_options` for the poll/user existence check.
Vote creation and deletion lock `polls.id`, bulk insert into `poll_votes`,
then update option counters with `id IN (?) AND poll_id = ?` and the poll
counter with `id = ?`. The staff voter listing adds `vote_count > 0` to the
poll-scoped option query. Existing `polls_pkey`, `poll_options_pkey`,
`index_polls_on_topic_id`, `index_poll_options_on_poll_id_and_label`,
`poll_votes_pkey`, and `index_poll_votes_on_poll_option_id_and_user_id`
cover these paths. The added parent predicates are correctness protections;
no shared poll index candidate is recommended.

### Wave D image and interaction helpers

`Philomena.Interactions.user_interactions/2` is the canonical image
interaction fan-out: four `UNION ALL` branches over `image_hides`,
`image_faves`, and up/down `image_votes`, each constrained by image IDs and
the actor's user ID. The actor-first API and empty-input short-circuit do not
change the non-empty SQL shape. Existing `(image_id, user_id)` unique indexes
and `user_id` indexes cover the branches; no shared candidate is recommended.
The merge workflow's association preloads and `ON CONFLICT DO NOTHING` inserts
retain the same image/user predicates; `RETURNING user_id` changes only result
materialization.

Image member loading and visibility are shared across Images, ImageFeatures,
ImageFaves, ImageHides, and interaction callers. `Loader.fetch` and
`fetch_and_authorize` remain primary-key lookups with caller-owned preloads;
Canada authorization is in memory. Featured-image selection retains the
`images.hidden_from_users = false` plus `image_features.created_at DESC LIMIT 1`
shape, with a viewer-hide `NOT EXISTS` branch covered by
`image_hides(image_id, user_id)`. The API's newly consistent personal-hide
filter is a correctness/visibility delta, not an index recommendation.

The image interaction persistence contexts share covered shapes: per-image
delete/replacement by `(image_id, user_id)`, merge inserts with the existing
unique conflict key, and user cleanup by `user_id` with batch `image_id`
selection. Image counter and user-stat updates are primary/unique key updates.
`ImageIntensities.put_for_loaded_image/2` adds an upsert on the existing unique
`image_intensities(image_id)` key; the image-delete cascade migration changes
referential behavior only. No shared index is proposed.

`ImageVotes.delete_user_votes!/2` has a confirmed Wave D follow-up from the
focused production review:
the cleanup relation filters `user_id` and `up`, then batches/orders by
`image_id`. Replace `image_votes(user_id)` with `(user_id, image_id)` so the
user equality and batch ordering are covered; `up` remains residual. Compare
that requested two-column shape with `(user_id, up, image_id)` during migration
review, and account for index size/write cost. The ImageVotes report owns it,
so no duplicate shared recommendation is made.

### Wave E gallery interactions and subscriptions

Galleries, Images, and the shared subscription helpers use the same
`gallery_interactions` predicates: membership/existence by
`gallery_id = ? AND image_id = ?`, owner-side batches by `image_id = ?`, and
gallery ordering by `gallery_id = ? ORDER BY position`. The unique pair,
`gallery_id`, `image_id`, and `(gallery_id, position)` indexes cover these
lookups and the gallery subscription unique `(gallery_id, user_id)` key covers
subscription existence/insert/delete. Gallery deletion now batches and locks
rows, but does not add an uncovered selector. The owner gallery selector's
`galleries.user_id = ? ORDER BY updated_at DESC LIMIT 100` is owned by
Galleries; the focused review finds the existing owner index sufficient for
the current unbounded production workload.

### Wave E tag and source history consumers

Profiles, Images, and IP/fingerprint profile controllers consume the canonical
TagChanges and SourceChanges history relations. Their page shapes are
user/image/IP/fingerprint equality (or inet containment) with
`created_at DESC, id DESC`, plus optional `added` predicates and association
preloads. Existing image/user/fingerprint/IP and tag-change join indexes cover
the selectors where present. Timestamp ordering suffixes and the missing
SourceChanges fingerprint index are intentionally deferred (the latter to a
possible OpenSearch migration) and are not repeated per consumer.

### Wave E duplicate-report visibility and locking

DuplicateReports and Images share report rejection/closure and image-pair
lookups. The current workflows add explicit image/report `FOR UPDATE` locks,
active-state predicates, and actor-dependent hidden-image visibility. Existing
image-direction, state/partial-state, foreign-key, and primary-key indexes
cover the relational access paths. The reverse-pair latest-row composite is
owned by DuplicateReports; no duplicate candidate belongs in shared findings.

### Wave E filter/tag-array maintenance

Filters' `put_replace_tag_references/5` performs separate bulk updates selected
by `hidden_tag_ids @> ARRAY[...]` and `spoilered_tag_ids @> ARRAY[...]`. Tags'
alias/deletion workflows call this helper and then reindex affected rows. This
is a moved, unchanged production workload; no GIN indexes are recommended.
The focused review instead calls for normalizing the filter/tag association
into an indexed join table. Tags' unchanged `images_count` ordering and
filter-array scans remain outside the master/current delta.

## Cross-context ownership links

- Activities is the canonical consumer report for homepage composition; its
  channel, topic, interaction, and subscription details link here.
- Channels owns provider/name maintenance and channel-specific alias updates;
  generic subscriptions and notification clears link here.
- ArtistLinks owns its admin state/order branches; tag canonicalization links
  here.
- ModNotes owns target-filtered note access; its shared Loader and moderation
  log writes link here.
- UserFingerprints and UserIps own their history/profile queries; Bans owns
  ban lookup shapes and Users owns profile-alias subqueries.
- Rules, SiteNotices, StaticPages, Adverts, and Badges record their Loader
  consumers here without duplicating the member-query finding.
- Profiles links the canonical profile locator and the IP/fingerprint history
  findings here; UserFingerprints owns the confirmed fingerprint ordering
  candidate and UserIps owns the confirmed replacement index.
- Users links delegated wipe and erasure selections here; Reports owns report
  closure, report-target preloads, and attribution wiping.
- Conversations, Commissions, and DnpEntries link their report-target loads
  and report-closing updates here rather than proposing duplicate indexes.
- Forums, Topics, Posts, and Comments link their hierarchy visibility, route
  scoping, preloads, and transaction locks here; Posts owns the confirmed
  last-post max-ID candidate and Topics owns the homepage/post-page findings.
- Polls, PollOptions, and PollVotes link their shared parent-scoped loading,
  existence, preload, lock, and counter-update shapes here; no poll candidate
  is duplicated in the summary.
- Images owns image member/featured/approval/navigation and image-child
  preload shapes; ImageFeatures, ImageFaves, ImageHides, ImageIntensities,
  ImageVotes, and Interactions link their detailed persistence and fan-out
  findings here. Duplicate comparison intensity ranges remain owned by
  DuplicateReports and are not re-recommended.
- Galleries owns gallery member, interaction, deletion, reorder, and owner
  selector queries; shared gallery subscriptions and notification clears link
  here without duplicate candidates.
- DuplicateReports owns perceptual intensity joins, report state/order
  branches, and the reviewed/rejected reverse-pair candidate; image visibility
  and report closure semantics link here.
- Filters owns owner/system pagination and the moved tag-array replacement
  workload; Tags links canonicalization and dependent cleanup. The array
  update shape is unchanged from production and should be normalized into an
  indexed join table rather than receiving speculative GIN indexes.
- TagChanges and SourceChanges own profile/image/IP/fingerprint history and
  attribution cleanup. Their timestamp/fingerprint ordering ideas are
  deduplicated in the summary and intentionally deferred, not repeated for
  Profiles consumers.

## Index conclusion

No new index is recommended solely for a shared helper. All shared equality,
foreign-key, primary-key, unique-conflict, subscription, interaction, profile
locator, report-target, tag-canonicalization, image interaction, gallery
interaction/subscription, and image member/preload paths have existing
coverage. The confirmed UserFingerprints, UserIps, Posts last-pointer, and
ImageVotes cleanup follow-ups arise in individual contexts and are deduplicated
in `summary.md`. Commission-item, SourceChanges history, DuplicateReports
reverse-pair, and Filters owner/order/array-GIN ideas were reviewed and rejected
or superseded by the normalization plan; none is a shared candidate.
