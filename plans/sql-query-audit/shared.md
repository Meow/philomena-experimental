# Shared SQL shape audit

Refs: master -> context-logic
Status: complete
Scope: Wave A, Wave B, and Wave C; read-only audit; no application code or migrations changed.

This report owns query shapes shared by multiple Wave A contexts, plus the
shared Loader, authorization, visibility, subscription, and transaction
helpers. Individual context reports link here rather than duplicating these
findings.

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
selectivity data.

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
`(user_id, updated_at DESC)`, while the fingerprint path may benefit from
`(user_id, updated_at DESC, id DESC)`. The latter is one deduplicated candidate
also owned by the UserFingerprints wave-A report; Profiles is a consumer and
does not produce a second candidate.

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
the timestamp branch; a partial `(topic_id, id) WHERE hidden_from_users IS
FALSE` index remains only a measured candidate for the max-ID branch and is
not recommended without representative plans and workload data.

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
  findings here; UserFingerprints owns the deduplicated fingerprint ordering
  candidate and UserIps owns the covered IP path.
- Users links delegated wipe and erasure selections here; Reports owns report
  closure, report-target preloads, and attribution wiping.
- Conversations, Commissions, and DnpEntries link their report-target loads
  and report-closing updates here rather than proposing duplicate indexes.
- Forums, Topics, Posts, and Comments link their hierarchy visibility, route
  scoping, preloads, and transaction locks here; Posts owns the measured
  last-post max-ID candidate and Topics owns the homepage/post-page findings.
- Polls, PollOptions, and PollVotes link their shared parent-scoped loading,
  existence, preload, lock, and counter-update shapes here; no poll candidate
  is duplicated in the summary.

## Index conclusion

No new index is recommended solely for a shared helper. All shared equality,
foreign-key, primary-key, unique-conflict, subscription, interaction, profile
locator, report-target, and tag-canonicalization paths have existing coverage.
The fingerprint ordered-history candidate, commission-item ordered-preload
candidate, and Wave C post last-pointer candidate arise in individual
contexts and are deduplicated in `summary.md`.
