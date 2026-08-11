# Activities context plan

Source: `lib/philomena/activities.ex`; primary consumer: `ActivityController`.

## Implementation status

Complete for wave 4.

- `load_front_page/4` remains the sole public Activities API. It authorizes the
  named homepage `:index` action and returns the typed `{:ok, %FrontPage{}}`
  result consumed by the controller.
- Actor is now authoritative: `scope.user` is replaced with `actor.user` before
  any image or watched-tag query, while Scope retains image filter, pagination,
  sort, and display state.
- Recent images, top-scoring images, recent comments, and watched images remain
  one OpenSearch multi-search. Anonymous actors receive `watched: nil`; signed-in
  actors receive a page. Compiler errors are returned, and search failures fail
  the whole request instead of silently substituting an empty strip.
- Comment visibility stays in Comments; channels delegate to
  `Channels.load_channels/4`; personal featured-image visibility is owned by
  `Images.featured_image/2`; and homepage topic visibility uses the shared forum
  hierarchy scopes through `Topics.list_front_page_topics/1`.
- Tests cover anonymous and signed-in assembly, empty groups, active filters,
  actor-over-Scope authority, watched tags, personal image hides, public/staff
  topic visibility, interactions, and both values of the NSFW-channel switch,
  including its browser cookie path.

## Findings

- `load_front_page/4` is already the sole public entry point, but the private
  homepage loaders directly compose queries from `Scope.user` and filter data.
  Visibility is therefore implicit in query construction rather than expressed
  as a documented authorization contract.
- The module layout is close to the target (one public API followed by private
  helpers) but must be inverted so private assembly precedes the documented API.
- The doc describes data assembly but needs explicit behavior for anonymous
  actors, the NSFW-channel switch, search failures, and empty result groups.

## Work

- Keep `load_front_page/4` as the only public API. Confirm `Scope` is necessary
  because image search needs filter/search state; still derive authorization
  solely from its actor/user and document that boundary.
- Audit each homepage section against the corresponding context's actor-scoped
  loader. Do not maintain a second visibility rule for comments, galleries,
  channels, or watched images in this aggregator.
- Decide whether one failed search section fails the whole page or yields an
  empty section, encode a named result contract, and test it. Do not rescue
  parser/OpenSearch errors ad hoc.
- Move private section/query helpers before `load_front_page/4`; add a spec and
  examples for anonymous and authenticated calls.

## Verification

- Cover anonymous, ordinary-user/filter, watched-tags, and NSFW-channel cases in
  `activities_test.exs` and `activity_controller_test.exs`.
- Re-run affected Images/Galleries/Channels tests after delegating visibility.
