# Channels SQL shape audit

Refs: master -> context-logic  
Status: complete

## Source set

Reviewed the Channels context and its nested persistence modules, the moved
channel controller/plug callers, the automatic updater, the channel and
subscription schemas, the shared `Philomena.Subscriptions` implementation,
the channel notification clear path, the tag-alias caller, related tests, and
`priv/repo/structure.sql` plus migration history.

Relevant files include:

- `lib/philomena/channels.ex`
- `lib/philomena/channels/automatic_updater.ex`
- `lib/philomena/channels/channel.ex`
- `lib/philomena/channels/query_builder.ex`
- `lib/philomena/channels/query_form.ex`
- `lib/philomena/channels/subscription.ex`
- `lib/philomena_web/controllers/channel_controller.ex`
- `lib/philomena_web/controllers/channel/read_controller.ex`
- `lib/philomena_web/controllers/channel/subscription_controller.ex`
- `lib/philomena_web/plugs/channel_plug.ex`
- `lib/philomena/subscriptions.ex`
- `lib/philomena/notifications.ex`
- `lib/philomena/notifications/channel_live_notification.ex`
- `lib/philomena/tags.ex`
- `priv/repo/structure.sql`

No application code, migrations, schemas, tests, or other audit reports were
changed.

## Changed shapes

### Channel listing: no search

**Classification: changed, index-relevant (join/preload shape), no new index
candidate.**

On `master`, the controller starts from `channels`, applies the optional
`nsfw = false` predicate and `last_fetched_at IS NOT NULL`, orders by
`is_live DESC, title ASC`, then always performs a left join to the associated
artist tag and uses that join for the preload. `Repo.paginate` issues the page
query and its count query from that relation.

On `context-logic`, `Channels.list_channels/4` applies the same visibility
predicates and ordering, but `QueryBuilder.build_query/1` does not add a tag
join when `cq` is absent. The associated artist tag is then loaded through an
association preload, which is a separate `tags WHERE id IN (...)` query. The
main page and count query therefore no longer carry the unnecessary left join.
The base filters, ordering, pagination, and selected channel rows are
otherwise unchanged.

Existing coverage: `channels.is_live`, `channels.last_fetched_at`, and the
primary key exist. The tag foreign-key index
`index_channels_on_associated_artist_tag_id` covers the association lookup;
the tag preload itself uses the primary key. No additional index is justified
by this refactor.

### Channel listing: `cq` search

**Classification: changed, index-relevant (join/filter/pattern shape), no
generic B-tree recommendation.**

Both refs use a left join from `channels.associated_artist_tag_id` to
`tags.id`, and match title, short name, or tag name. The current query keeps
the same OR structure and retains the listing predicates and ordering, but it
also uses the association preload rather than the explicit joined preload.

The pattern construction changed. `master` uses `cq%` for `title` and
`short_name`, and `%cq%` for the tag. The current `like_sanitize/1` first
wraps the input in `%`, so the effective title/short-name pattern is
`%cq%%` and the tag pattern is `%%cq%%`. This introduces a leading wildcard
for all three `ILIKE` operands, making ordinary B-tree indexes unsuitable.
It is a correctness/performance follow-up, not an index recommendation.

The existing `tags.id` primary key and
`index_channels_on_associated_artist_tag_id` cover the join. Leading-wildcard
`ILIKE` needs specialized trigram/expression analysis and workload evidence;
no such candidate is proposed in this audit. The existing unique
`index_tags_on_name` is not useful for the leading-wildcard tag search.

## Unchanged or non-index-relevant sites

### Live-channel count

**Classification: unchanged.**

The old `ChannelPlug` aggregates `count(id)` over `channels WHERE is_live =
true`. The current plug delegates to `Channels.count_live_channels/0`, which
aggregates the same relation with `count(*)` semantics. This is a module and
aggregate-expression refactor, not a changed access requirement. The existing
`index_channels_on_is_live` covers the predicate.

### Member loading and authorization

**Classification: changed, likely not index-relevant.**

The old controller authorization plug loads a channel by its primary key and
places it in assigns. The current context uses
`Loader.fetch_and_authorize/5`, which parses the integer ID and performs the
same primary-key `Repo.get` before authorization. Show, edit, update, delete,
read, and subscription operations all use this loader; update additionally
preloads `associated_artist_tag` before applying the artist-tag changeset.

The primary-key lookup is covered. The new preload is an association query
covered by the channel foreign-key index and tag primary key. Authorization is
performed after loading in both designs; malformed/out-of-range IDs now
normalize to `not_found`, which is a behavior change but not an index issue.

### Create/update artist-tag workflow

**Classification: changed, index-relevant supporting queries; existing tag
indexes cover them.**

`master` resolves the submitted artist tag through the tag name lookup and
then writes `associated_artist_tag_id`. `context-logic` canonicalizes the
submitted name set through the Tags context inside `Philomena.Multi`, then
writes the resolved association. This changes the supporting tag lookup and
transaction composition, while the channel insert/update row target remains
the channel primary key.

The tag name lookup is covered by the unique `index_tags_on_name`; the channel
association write and any association preload are covered by
`index_channels_on_associated_artist_tag_id`. Canonicalization/locking is
owned by Tags and should be considered with the Tags audit; no Channels index
candidate is proposed.

### Automatic updater

**Classification: unchanged query shapes, moved ownership.**

The offline update is the same `UPDATE channels SET is_live = false,
updated_at = ? WHERE type = ? AND short_name NOT IN (?)`, moved from
`AutomaticUpdater` to `Channels.mark_provider_channels_offline/3`.

The online lookup remains `SELECT channels.* FROM channels WHERE type = ? AND
short_name IN (?)`, followed by per-row updates through the channel primary
key. The current code renames `update_channel_state/2` to
`update_fetch_state/2`; neither the predicates nor write targets changed.

There is no index on `(type, short_name)` in the structure dump. The existing
indexes on `is_live`, `last_fetched_at`, and `associated_artist_tag_id` do not
cover these provider/name predicates. A composite `(type, short_name)` index
could help the online `IN` lookup and the offline update, but this audit has
no representative `EXPLAIN`, cardinality, or workload-frequency evidence;
it is recorded as an unsupported candidate rather than recommended.

### Channel subscriptions

**Classification: unchanged shared shapes; moved controller calls.**

The generic subscription helpers issue:

- existence: `channel_subscriptions WHERE channel_id = ? AND user_id = ?`;
- page fan-out lookup: `channel_id IN (?) AND user_id = ?`;
- insert with `ON CONFLICT DO NOTHING` on the subscription key; and
- delete: `channel_id = ? AND user_id = ?`.

The current context-facing functions first load and authorize the channel,
then invoke the same helpers. The unique
`index_channel_subscriptions_on_channel_id_and_user_id` covers member
existence, insert conflict detection, and delete; the user-only index covers
the user-side access pattern. No new index is proposed.

### Channel notification clear and preload

**Classification: changed shared ownership, same relevant predicates.**

Channel show/read/unsubscribe now call `Notifications.clear_channel_live/2`.
The current clear query deletes from `channel_live_notifications` with
`channel_id = ? AND user_id = ?`; the old channel callback called the prior
notification helper with the same effective predicate. Notification category
loading still filters by `user_id` and preloads the channel by primary key.

Existing `channel_live_notifications_user_id_channel_id_index` covers the
two-column clear predicate (with `user_id` first), and the dedicated
`channel_live_notifications_channel_id_index` covers channel-side access.
The notification preload uses the channel primary key. No index action is
needed; shared notification behavior belongs in `shared.md`.

## New, deleted, moved, or ambiguous sites

### Artist-tag alias replacement

**Classification: new/deleted/unpaired (moved ownership), index-relevant.**

`context-logic` adds `Channels.put_replace_artist_tag/4`, an update-all query
of the form `UPDATE channels SET associated_artist_tag_id = ? WHERE
associated_artist_tag_id = ?`, invoked from the Tags alias transaction. There
is no directly corresponding Channels function on `master`; the current
function supplies the channel leg of an existing alias-replacement workflow.

`index_channels_on_associated_artist_tag_id` directly covers the selection
predicate. No additional index is proposed.

## Index inventory and recommendations

Relevant indexes in `priv/repo/structure.sql`:

| Relation                     | Existing coverage                                                                               |
| ---------------------------- | ----------------------------------------------------------------------------------------------- |
| `channels`                   | primary key; `associated_artist_tag_id`; `is_live`; `last_fetched_at`                           |
| `channel_subscriptions`      | unique `(channel_id, user_id)`; `(user_id)`                                                     |
| `channel_live_notifications` | `(channel_id)`; unique `(user_id, channel_id)`; `(user_id, read)`; `(user_id, updated_at DESC)` |
| `tags`                       | primary key; unique `name`; unique `slug`; `aliased_tag_id`                                     |

No index candidate is recommended for Channels. The only plausible missing
access path is `(type, short_name)` for automatic provider maintenance, but the
focused review rejects it at the current table size (727 channels). The `cq`
searches require specialized analysis because of OR predicates and
leading-wildcard `ILIKE`; a generic B-tree would not be an evidence-backed
recommendation.

## Correctness/performance follow-ups (not index recommendations)

- `QueryBuilder.like_sanitize/1` briefly added leading/trailing wildcards,
  changing prefix search into contains search; the focused review says this was
  fixed and the Commissions helper aligned. Retain a regression test.
- The refactored search query should be checked for duplicate rows/count
  behavior if the artist-tag association ever ceases to be one-to-one.
- The `type`/`short_name` provider maintenance workload remains covered by the
  current small table; no composite index is planned unless cardinality or
  workload changes materially.
- Authorization, notification clearing, and subscription helper queries are
  shared concerns and should be linked from the coordinator's `shared.md`.

## Follow-ups

- Keep regression coverage for the corrected `like_sanitize/1` behavior; no
  index action follows from the fixed helper.
- The provider `(type, short_name)` workload has no evidence-backed candidate;
  measure it before proposing a composite index.
