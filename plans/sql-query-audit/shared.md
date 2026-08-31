# Shared SQL shape audit

Refs: master -> context-logic
Status: complete

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

## Index conclusion

No new index is recommended solely for a shared helper. All shared equality,
foreign-key, primary-key, unique-conflict, subscription, interaction, and tag
canonicalization paths have existing coverage. Ordered composite candidates
that arise in individual contexts are deduplicated in `summary.md`.
