# Context-owned presentation policy

Status: proposed for review

Baseline: `context-policy` and `context-logic-for-review` both point to
`d2d234ff` (`Move Philomena domain logic to contexts`) at the time this plan was
written. The inventory below therefore describes the remaining policy work on
top of that common context-refactor baseline.

## Design principles (review first)

1. **A context result is already safe and useful for its actor.** A controller,
   view, JSON renderer, worker, or other caller must not have to reconstruct
   whether a field may be disclosed or an action may be offered. Public context
   reads accept `%Philomena.Attribution.Actor{}` and return viewer-specific
   results.

2. **Treat access, disclosure, and affordances as separate decisions.**

   - Access decides whether the operation may return a resource at all and
     continues to use `Philomena.Authorization.authorize/3` with the established
     `:not_found`/`:unauthorized` contracts.
   - Disclosure decides which sensitive values the successful result contains:
     hidden media, anonymous identity, IP/fingerprint, deleted content and
     moderator identity, private links, DNP reason/feedback, profile moderation
     data, and similar fields.
   - Affordances describe which actions the actor can currently attempt. They
     drive links, buttons, forms, tabs, and staff navigation, but they do not
     authorize the eventual request.

3. **Protect data by construction, not only with a rendering boolean.** Prefer
   omitting a sensitive section, setting a typed optional field to `nil`, or
   returning a redacted projection over returning the raw value plus
   `show_value?: false`. A forgotten template condition must not disclose the
   value. A boolean is appropriate when the underlying data is not sensitive,
   such as whether an Edit link is available.

4. **Use explicit, domain-specific result types.** Extend the page structs
   introduced by the context refactor and add small typed entry/projection
   structs for reused collection partials. Name fields after domain outcomes
   (`can_edit?`, `can_approve?`, `visible_body`, `identity_metadata`) rather than
   exposing a generic `{action, subject}` authorization API to the web layer.
   Do not put viewer-specific virtual fields on persisted Ecto schemas.

5. **Use an available changeset as the affordance when one already exists.**
   `ImagePage` currently makes an unavailable form `nil`; retain that useful
   contract. Do not add a second `can_edit_metadata?` flag when the sole
   consumer is `tag_changeset != nil`. Add an explicit capability for links,
   method buttons, alternative transitions, and disclosures that have no
   changeset.

6. **Keep Canada behind the application boundary.**
   `Philomena.Users.Ability` remains the canonical ruleset during this refactor,
   and `Philomena.Authorization` remains the only adapter to it. Contexts may
   calculate successful-result policy with a boolean helper in
   `Philomena.Authorization`; controllers, plugs, views, templates, and JSON
   renderers may not call Canada or that helper. Domain-owned policy can later
   replace Canada without changing presentation contracts.

7. **Never trust an affordance on a write.** Every create/update/delete context
   operation keeps its own write-access, loading, authorization, state-transition,
   and locking checks. Page capabilities are a snapshot for presentation, not
   a token and not protection against stale state or a forged request.

8. **Compose every prerequisite once.** Available actions must include all
   application prerequisites relevant at page-load time: authentication,
   active ban, fingerprint/write access, ownership, role-map permission,
   resource state, parent state, and hard limits such as the topic post cap.
   Templates may still combine capabilities with genuinely presentational
   preferences such as the `hide_staff_tools` cookie.

9. **Decorate collections in batches.** A page that renders comments, posts,
   images, filters, users, reports, or notes returns entries paired with their
   disclosure/action projection. Policy calculation must use the actor and
   already loaded records and must not introduce per-entry queries. Shared
   partials consume the decorated entry rather than `@conn`.

10. **Keep HTTP and rendering concerns out of policy.** Context results contain
    records, safe values, and domain decisions, never `%Plug.Conn{}`, cookies,
    routes, HTML, rendered Markdown, CSS classes, or button labels. Controllers
    remain responsible for Markdown rendering and adapting result fields to
    template assigns.

11. **Apply the same disclosure contract to every output format.** HTML, JSON,
    RSS, oEmbed, client-side datastore values, previews, notifications, and
    firehose payloads must not invent independent redaction rules. Where a
    trusted internal broadcast intentionally has a different audience, give it
    an explicitly named system projection rather than relying on a renderer
    clause that happened not to receive `conn`.

12. **Migrate behavior deliberately.** First characterize current differences
    across anonymous, user, assistant, moderator, privileged moderator, and
    admin actors. Preserve intended behavior, call out contradictory gates, and
    fix an unsafe disclosure rather than cementing it as compatibility. Each
    slice adds its context contract and tests before removing the corresponding
    presentation check.

### Proposed result shape

Use page-specific policy structs where a page has several decisions, and small
entry structs where a partial is shared across pages. For example (names are
illustrative and should be finalized in the first slice):

```elixir
%ImagePage{
  image: image,
  comments: %Scrivener.Page{entries: [%CommentEntry{}]},
  policy: %ImagePage.Policy{
    can_hide?: true,
    can_approve?: false,
    can_destroy?: false,
    identity_metadata: %Attribution.IdentityMetadata{ip: ip, fingerprint: fp}
  },
  file_changeset: changeset_or_nil
}

%CommentEntry{
  comment: comment,
  visible_body: body_or_nil,
  attribution: %Attribution.Disclosure{},
  deleted_by: disclosed_moderator_or_nil,
  policy: %CommentEntry.Policy{can_edit?: false, can_hide?: true, can_delete?: true}
}
```

The application layer should not render Markdown. In practice `visible_body`
will initially be the raw body or `nil`; the controller renders only non-`nil`
values. For list entries whose complete record is not sensitive, the wrapper
may retain the record while sensitive associations/fields are carried only in
the safe projection.

### Decisions to approve before implementation

- Approve explicit typed page/entry policy structs as the default instead of a
  generic `MapSet` of Canada action atoms. This creates more code but gives the
  web layer a stable vocabulary independent of Canada and makes disclosures
  visible in typespecs.
- Approve omission/redaction as the default disclosure strategy, even where it
  changes controller assigns from raw records to entry structs.
- Approve a small `Philomena.Administration` read context for the global staff
  navigation/counter aggregate. The layout is application-wide and does not
  belong to any one resource context; the aggregate should call the existing
  owning contexts rather than query their tables itself.
- Keep `hide_staff_tools` as a web preference. It may suppress an already
  authorized control but must never reveal one or suppress disclosure from the
  application result.

## Current-state inventory

There are 126 `can?/3` occurrences in 49 files under `lib/philomena_web`: 92 in
templates and 34 in view modules (including the `AppView.can?/3` definition and
its Canada call). The most common actions are `:edit` (28), `:hide` (25),
`:index` (18), `:show` (15), `:approve` (6), and `:create` (5).

The calls are not the whole policy surface. The same layer also derives policy
through role checks, actor/owner ID comparisons, `current_ban`, resource flags,
and public/anonymous state. Important examples include:

- role checks in the layout, settings, profile, and user/subnet/fingerprint ban
  templates;
- ownership checks on profiles, commissions, reports, private messages, and
  artist links;
- hidden/deleted/pending checks on images, topics, posts, comments, and
  messages;
- public/internal checks on rules and artist links;
- disclosure clauses in the JSON image/comment/post/gallery/artist-link views;
  and
- image URL selection and identity metadata written into HTML data attributes
  or JSON.

These are in scope when they answer either “may this viewer know this value?”
or “may this viewer attempt this domain action?” Authentication-only layout
choices, cosmetic state labels, and ordinary rendering choices remain in the
web layer.

## Target boundaries and vocabulary

### Authorization helper

Add a documented boolean predicate to `Philomena.Authorization` for contexts
that assemble successful result policy, for example
`permitted?(actor, action, subject)`. It delegates to the same Canada rules as
`authorize/3`. Keep `authorize/3` for gates and error-producing workflows.
Static boundary checks must ensure neither function is called from
`PhilomenaWeb` presentation code.

Do not expose a public context function whose only purpose is arbitrary
permission probing (`Images.can?(actor, action, image)`). Public context reads
return a complete result for their use case; private policy builders may be
reused inside the owning context.

### Disclosure types

Create shared types only for genuinely shared domain concepts:

- `Philomena.Attribution.Disclosure` for public identity, anonymous display,
  optionally revealed account identity, and optionally disclosed IP/fingerprint;
- an image-media projection owned by `Philomena.Images` for the versions/URIs
  an actor may receive; and
- a viewer/session policy used by application shell data.

Keep DNP details, profile moderation data, deleted communication bodies, and
similar concepts in their owning page/entry types. Do not build one universal
presentation DTO.

### Controller and template contract

Controllers may flatten page structs into assigns during migration, but they
must pass the policy/projection field through unchanged. Views may answer
formatting questions from that value (for example a CSS class for a redacted
entry); they may not accept `conn` or `current_user` to answer authorization or
disclosure questions. Reusable partials should eventually receive one entry
projection plus cosmetic options.

## Migration plan

### Phase 0 — Characterize and establish a migration ledger

1. Turn the inventory in this document into an executable/checked ledger of
   every `can?/3` call and adjacent role/ownership disclosure predicate. Mark
   each as access, disclosure, affordance, or presentation-only.
2. Add focused controller/rendering characterization tests before changing each
   domain. Cover actor levels that actually differ in `Users.Ability`, including
   assistant `role_map` variants and privileged moderators—not only the four
   broad roles.
3. Add state variants relevant to the page: owned/unowned, hidden/visible,
   approved/pending, destroyed/intact, locked/unlocked, banned/unbanned,
   public/private/internal, anonymous/named, and request/listed/closed DNP.
4. For disclosures, assert absence from the full response or serialized map,
   not merely absence of a label. Search HTML data attributes, inline JSON,
   URLs, raw bodies, IDs, IPs, fingerprints, tokens, and private associations.
5. Record contradictions as explicit decisions rather than choosing whichever
   duplicate predicate is easiest to retain. Examples to review include the
   profile tag-change role branch whose two arms are identical, the mixture of
   `:show, :ip_address` and `:show, :identity_metadata`, and controls grouped
   under broad `:hide`/`:edit` gates even though their write endpoints use more
   specific actions.

Exit criterion: every known presentation policy decision has a target context,
result field, and test location in the ledger.

### Phase 1 — Add policy foundations and guardrails

1. Add `Philomena.Authorization.permitted?/3` (or the agreed name), with the
   same accepted actor types and tests as `authorize/3`.
2. Add the shared attribution and image-media disclosure structs after their
   first real consumer requires them; do not front-load unused abstractions.
3. Extend `Philomena.ContextBoundaryCheck` to reject direct Canada calls from
   all `lib/philomena_web/**/*.ex`, not only domain code. Add a Slime-aware or
   narrow textual test that rejects `can?(` in templates.
4. Once consumers have migrated, also reject calls/imports of the boolean
   authorization helper from controllers, plugs, views, and renderers, and
   delete `PhilomenaWeb.AppView.can?/3`.
5. Add a targeted presentation-policy check for new role/role-map and
   actor/owner comparisons in templates and views. Maintain a small reviewed
   allowlist for fields that are displayed as data rather than used as policy.

Exit criterion: new presentation policy cannot be added through the old path,
while an explicit temporary allowlist accounts for calls not yet migrated.

### Phase 2 — Application shell and session-wide capabilities

Affected code includes `LayoutView`, `_header.html.slime`,
`_header_staff_links.html.slime`, `AdminCountersPlug`, `SettingView`, and the
settings template.

1. Add `Philomena.Administration.load_navigation(actor)` returning explicit
   management destinations and optional authorized queue counters. It composes
   `Images`, `DuplicateReports`, `Reports`, `ArtistLinks`, and `DnpEntries`
   public count APIs; those contexts retain query ownership.
2. Add a viewer/session result owned by `Users` for signed-in state and global
   domain capabilities such as batch tagging and staff-only settings. Keep
   theme, rounded tags, and other cosmetic settings as ordinary preferences.
3. Replace the layout’s eleven Canada-backed helpers and its `role != "user"`
   staff menu checks with the navigation result. Do not use “staff” as a proxy
   when destinations differ for privileged assistants/moderators.
4. Make `AdminCountersPlug` consume the administration result instead of
   deciding staff status from `user.role`; do not execute inaccessible counter
   queries.
5. Replace `ImageView`/`SearchView` global batch/hide helpers and the settings
   role checks with viewer-policy fields supplied by their context/page result.
6. Keep the `hide_staff_tools` cookie in the web layer and combine it only with
   positive domain capabilities.

Exit criterion: the shared layout and settings views contain no authorization,
role-map, or role-category decisions.

### Phase 3 — Images and media disclosure

Affected code includes `ImagePage`, image show/deleted templates, image
partials, `ImageView`, `DuplicateReportView`, `SearchView`, approval pages, and
every gallery/tag/profile/activity/search surface that renders an image card.

1. Extend `ImagePage` with a typed policy and safe media/attribution
   projections. Consolidate the existing `can_interact` and nil changeset
   conventions rather than duplicating them.
2. Calculate all image-page affordances in `Images.show_image_page/3`:
   edit description/metadata, view staff tools, hide/unhide, approve, destroy,
   replace file, feature, repair, clear hash, lock/unlock comments/description/
   tags, edit uploader/anonymity/scratchpad, report, subscribe, vote/fave/hide,
   and gallery membership actions. Include ban and write-access prerequisites
   for controls whose endpoints require them.
3. Return only media versions/URIs the actor may receive. Replace calls where
   `thumb_urls/2` or `thumb_url/3` is passed `can?(:show/:hide, image)`, including
   hidden image data attributes and duplicate-report thumbnails. Verify that
   hidden originals and derivative URLs cannot enter HTML, JSON, oEmbed, or
   client-side datastore output for a forbidden actor.
4. Carry image uploader attribution and optional identity metadata through the
   shared attribution disclosure. Do not pass raw IP/fingerprint merely because
   a template is expected to hide it.
5. Introduce a reusable image entry/projection for image grids and lists.
   Update image search/list APIs, `TagPage`, `GalleryPage`, `ProfilePage`, front
   page results, related/random/navigation results, duplicate reports, and the
   approval queue to return or attach it without per-image queries.
6. Make templates branch on result fields or changeset presence only. Resource
   state may still choose the label/verb (Lock versus Unlock) after the context
   has said that management action is available.
7. Keep every image write endpoint’s context authorization intact and add
   parity tests between page affordances and write eligibility for stable
   state, plus stale-state tests showing the write still rejects changes.

Exit criterion: no image renderer computes visibility or action availability
from actor, role, ban, or Canada, and forbidden media locators are absent from
all outputs.

### Phase 4 — Attribution, comments, posts, topics, and messages

Affected code includes `UserAttributionView`, comment/post/message partials,
`CommentView`, `PostView`, `TopicPage`, topic/poll templates, comment/post
histories, activity/forum/notification strips, and conversation pages.

1. Add `Attribution.disclose(actor, object)` as an application-layer operation
   (with a batch form if it needs loaded users/awards). It returns the public or
   anonymous identity representation and includes a linked underlying account
   and identity metadata only when disclosed. The web helper renders this value
   and no longer receives `conn` for policy.
2. Replace `:reveal_anon`, `:show, :ip_address`, ad hoc anonymity checks, and
   staff-role badges with the shared disclosure across images, comments, posts,
   topics, galleries, reports, changes, histories, activity, forums, and
   notifications.
3. Add viewer-specific `CommentEntry` and `PostEntry` results containing raw
   visible body (or `nil`), disclosed deletion reason/deleting moderator,
   attribution, identity metadata, and explicit approve/edit/hide/unhide/
   destroy-content actions. Use them in both standalone listings and nested
   `ImagePage`/`TopicPage` results.
4. Update controllers to render Markdown only for `visible_body`; never render
   and then hide a forbidden deleted body in the template. Apply the same rule
   to version/history pages.
5. Extend `TopicPage` with topic-level capabilities: moderation tools,
   title/poll editing, lock/stick/move/hide transitions, reply availability,
   poll vote/list/delete actions, and subscription state. The reply decision
   includes authentication, ban/write access, hidden/locked state, and the
   200,000-post cap now combined in the template.
6. Add a message entry/result that discloses a pending message body only to its
   sender or an approver and exposes `can_approve?`. Remove the template’s
   direct sender-ID comparison.
7. Keep notification records minimal: if a notification partial needs only a
   safe display attribution, return that projection instead of a fully loaded
   anonymous object.

Exit criterion: communication bodies, deleting moderators, anonymous accounts,
IP addresses, and fingerprints are disclosed by context results; their partials
do not inspect the viewer.

### Phase 5 — Profiles, users, artist links, awards, and registration

Affected code includes `ProfilePage`, `Profiles`, `ProfileController`,
`ProfileView`, profile and commission partials, registration edit, admin user
lists, and user/subnet/fingerprint ban listings.

1. Make `ProfilePage` the complete viewer-specific contract. Add explicit
   personal and staff actions (edit title/description/avatar, view own reports,
   manage commission/links/awards, view source/tag changes, ban, edit account,
   reset keys, verify, force filter, unlock, wipe/erase, revert tag changes).
2. Stop loading sensitive sections and then relying on the template to hide
   them. Return optional disclosed sections for forced filter, ban history,
   admin metadata, moderation scratchpad/notes, and name history. Fold the
   controller’s `admin_assigns` orchestration into the application result or a
   single `Profiles.load_profile_moderation` result used by `show_profile`.
3. Filter private artist links in `Profiles`/`ArtistLinks` for the actor. Attach
   per-link edit/reject/status/watcher-count disclosure; do not expose a private
   link or watcher count and then use `should_see_link?/3` to suppress it.
4. Attach per-award edit/delete and awarding-user disclosure. Preserve the
   `hide_staff_tools` preference only as a final UI suppression.
5. Give commission show/directory results owner/manager capabilities, including
   per-item edit controls. Replace all profile/commission `current?/2` checks
   used as policy; identity comparisons used only for prose may remain.
6. Make `Users` return `can_change_username?` with the registration/settings
   page result so the 90-day rule is not recomputed in the template.
7. Add per-row policy to admin user and ban listings. Replace raw admin-role
   checks for destructive ban/user operations with the exact action each
   endpoint authorizes.
8. Review API profile output, authentication tokens in settings, and all admin
   profile fields under the same disclosure tests even where no current
   `can?/3` call exists.

Exit criterion: profile-related templates do not decide ownership, staff level,
private-link visibility, moderation-data visibility, or action availability.

### Phase 6 — Tags, tag/source changes, and DNP entries

Affected code includes `TagPage`, tag edit/info templates, `TagView`,
`TagChangePage`, `SourceChangePage`, their views/templates, and `DnpEntryPage`.

1. Add tag page/edit policy for edit, alias, image management, channel editing,
   related artist-link/DNP administration, and batch update. Per-channel action
   data belongs with each channel/tag association entry.
2. Add listing policy to tag/source change page results and per-entry disclosed
   attribution/identity metadata. Replace `reverts_tag_changes?/1`,
   `:show, :ip_address`, and staff-role label derivation with context-owned
   results.
3. Standardize the identity permission on the existing
   `:show, :identity_metadata` domain action; treat `:ip_address` as a legacy
   presentation alias to remove after behavior comparison.
4. Extend `DnpEntryPage` so reason and feedback/instructions are absent when not
   disclosed. Add explicit edit and allowed-transition results. Prefer an
   allowed transition set derived by the DNP state machine and authorization
   over a broad `can_transition?` followed by a template-owned state table.
5. Keep optional mod notes as a disclosed page section and attach row-level mod
   note actions as described in Phase 8.

Exit criterion: tag/history/DNP templates contain no identity, disclosure, or
transition policy.

### Phase 7 — Filters, galleries, commissions, channels, rules, and pages

1. Extend `FilterPage` and filter listing entries with edit/delete/publish and
   related tag-management actions. System/public/owner visibility remains a
   context query/access decision; templates receive only visible filters.
2. Extend `GalleryPage` and gallery list results with owner/manager,
   subscription, image add/remove/reorder, edit/delete, and report actions.
   Remove `show_subscription_link?` and owner checks used as policy.
3. Complete commission policy migration not covered by ProfilePage: directory
   create/view-own affordances, listing edit/delete, and per-item actions.
4. Attach create/edit/subscription/NSFW/read capabilities to channel index and
   channel entries; replace class/member Canada checks in `ChannelView` and
   templates.
5. Return rule entries that are already visible and decorated with edit
   capability. Keep `hidden` and `internal` as displayed state only for actors
   to whom those records were disclosed.
6. Add static-page index/show capabilities for edit/history controls rather
   than probing `StaticPage` from the template.

Exit criterion: these smaller domain surfaces use the same context-result
contract, with no fallback to global layout capabilities for member-specific
actions.

### Phase 8 — Moderation queues and per-row actions

Affected surfaces include approvals, duplicate reports, reports, mod notes,
admin users, artist links, and all ban types.

1. Return typed queue entries with the exact allowed row actions instead of
   relying on the fact that the actor reached an admin index. This covers image
   approve/hide, duplicate accept/reverse/claim/reject, report claim/unclaim/
   close, mod-note update/delete, artist-link verify/reject/contact, and user/ban
   actions.
2. Move report assignment comparisons (`report.admin == current_user`) into
   report entry capabilities. Keep claimed/unclaimed state available for labels
   but not as the authority for a control.
3. Replace broad gates that do not match endpoint actions, such as
   `can?(:edit, report)` or class-level user checks, with exact domain-named
   fields calculated using the endpoint’s action.
4. Ensure queue counts and links use the same application aggregate introduced
   in Phase 2, so a visible counter never points at a destination the actor
   cannot access.

Exit criterion: reaching an admin page and seeing each individual operation are
separate context-owned decisions with endpoint parity tests.

### Phase 9 — JSON, RSS, oEmbed, client data, and broadcasts

1. Inventory renderer clauses that redact from raw schema state even without
   Canada calls: hidden images/topics/posts/comments, anonymous uploader/author,
   private artist links, galleries, filters, and profiles.
2. Make API context operations return explicit public projections or the same
   safe entry projections used by HTML. JSON views should serialize their input
   and perform formatting only; they must not decide whether a field exists.
3. Define separate, explicit projections for RSS, oEmbed, and firehose where
   their audience differs. In particular, remove the implicit security meaning
   of calling `ImageView.render` with versus without `conn`.
4. Verify client-side datastore data cannot contain hidden media URIs,
   undisclosed IDs, identity metadata, or actions that the server result did not
   grant.
5. Keep `openapi.yaml` synchronized if a response schema changes. The intended
   first pass is behavior-preserving, but any correction to unsafe historical
   disclosure must be documented as an API change.

Exit criterion: output renderers contain no actor-sensitive branching; choosing
the correct application projection is the controller/context caller’s job.

### Phase 10 — Remove compatibility paths and document the rule

1. Delete `AppView.can?/3` and authorization-only helpers in `LayoutView`,
   `ProfileView`, `TagView`, `TagChangeView`, `ImageView`, `SearchView`, and
   `DuplicateReportView`.
2. Remove all temporary inventory allowlists. Require zero `Canada.Can.can?` and
   zero `can?(` calls beneath `lib/philomena_web`, including templates.
3. Audit remaining `current_user`, `current_ban`, role, role-map, ownership, and
   sensitive-state predicates in views/templates. Classify and remove any that
   still decide disclosure or actions; leave only authentication layout,
   preferences, displayed state, and formatting.
4. Update `CONTEXT_STYLE.md` with the access/disclosure/affordance distinction,
   safe-by-construction guidance, collection-entry rule, and examples from the
   completed image and profile slices.
5. Update page/result moduledocs and public context specs so each optional
   sensitive field and action capability has a precise contract.

Exit criterion: static boundary tests prevent regression and repository
documentation makes context-owned presentation policy the default for new work.

## Domain migration ledger

| Area                      | Current presentation-policy sites                                                             | Target context/result                                                 |
| ------------------------- | --------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Global layout/admin links | `layout_view.ex`, layout header/staff partials, `AdminCountersPlug`                           | `Administration.Navigation` plus `Users.ViewerPolicy`                 |
| Images/media              | image templates, `image_view.ex`, `search_view.ex`, `duplicate_report_view.ex`, approval rows | `Images.ImagePage` plus reusable `Images.ImageEntry`/media disclosure |
| Attribution/identity      | `user_attribution/_anon_user`, image/comment/post/change templates                            | `Attribution.Disclosure` and optional identity metadata               |
| Comments                  | comment partials and comment/profile/activity listings                                        | `Comments.CommentEntry` returned by comment page/list APIs            |
| Posts/topics/polls        | post partials, `topic/show`, poll display, histories                                          | `Topics.TopicPage`, `Posts.PostEntry`, topic policy                   |
| Messages                  | `message/_message`, conversation show                                                         | conversation/message page entry policy                                |
| Profiles/users            | `profile_view.ex`, profile templates, registration edit, admin user list                      | expanded `Profiles.ProfilePage`, user/list entry policies             |
| Artist links/awards       | profile link/award blocks and admin artist-link pages                                         | actor-filtered link/award entry projections                           |
| Filters                   | filter show/list partials                                                                     | expanded `Filters.FilterPage` and filter entries                      |
| Galleries/commissions     | gallery show, commission sidebar/items/directory                                              | expanded gallery/directory/listing results                            |
| Tags                      | `tag_view.ex`, tag edit/info templates                                                        | expanded `Tags.TagPage` and edit result policy                        |
| Tag/source changes        | their views/index templates                                                                   | expanded page plus safe change entries                                |
| DNP                       | `dnp_entry/show`                                                                              | expanded `DnpEntryPage` with optional details/transitions             |
| Channels/rules/pages      | channel boxes/index, rule index/row, page show                                                | decorated list/show results from owning contexts                      |
| Moderation queues         | approvals, duplicates, reports, notes, bans                                                   | typed per-row action projections plus administration aggregate        |
| APIs/feeds/broadcasts     | API JSON views, RSS, oEmbed, firehose render calls                                            | explicit audience-specific safe projections                           |

## Testing and verification strategy

For each domain slice:

1. Add context tests asserting the exact result shape, including absent
   sensitive values and all positive/negative capabilities for the relevant
   actor/state matrix.
2. Add controller tests that assert both presence and absence of action markers
   and sensitive values. Continue following `test/CONVENTIONS.md` for auth
   levels, fixtures, search setup, and exact JSON structures.
3. Test that a hidden control does not weaken endpoint authorization: submit the
   underlying route directly as a forbidden actor and assert the established
   error. Test that an offered action succeeds in the unchanged state.
4. Test stale/racing state at the mutation context where applicable; do not add
   database locking to read-only policy assembly.
5. For disclosure, test all serialization surfaces that consume the projection,
   not only the primary HTML page.
6. Run targeted context/controller tests inside the `app` container with
   `MIX_ENV=test`, then `mix format --check-formatted`. Run
   `scripts/philomena.sh test` only after a coherent phase or final migration.

Application-wide completion checks:

```bash
rg -n 'Canada\.Can\.can\?|\bcan\?\(' lib/philomena_web
rg -n 'role_map|\.role\s*(==|!=|in)|current\?\(' \
  lib/philomena_web/views lib/philomena_web/templates
docker compose exec -T -e MIX_ENV=test app \
  mix test test/philomena/context_boundary_check_test.exs
scripts/philomena.sh test
```

The first command must return no matches. Matches from the second require
review: a role printed as account data is acceptable; a role, ownership, or
actor comparison deciding disclosure or actions is not.

## Completion criteria

- All request-facing contexts remain independently usable without Phoenix and
  return actor-specific safe data and affordances.
- No controller, plug, view, template, JSON/RSS renderer, or shared web helper
  invokes Canada or a generic authorization predicate.
- No sensitive value is passed to presentation code unless that caller may
  disclose it; hidden media URLs and identity metadata receive explicit leak
  tests.
- No presentation code derives an available domain action from role, role-map,
  ownership, ban, or resource state.
- Every mutation still authorizes and validates at execution time.
- Shared list partials consume typed decorated entries without N+1 policy
  queries.
- HTML, API, feed, oEmbed, client data, notification, and broadcast contracts
  use explicit safe projections.
- The architecture check and `CONTEXT_STYLE.md` prevent the old pattern from
  returning.
