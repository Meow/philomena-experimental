# Activities context plan

Source: `lib/philomena/activities.ex`; primary consumer: `ActivityController`.

## Findings

- `load_front_page/3` is already the sole public entry point, but the private
  homepage loaders directly compose queries from `Scope.user` and filter data.
  Visibility is therefore implicit in query construction rather than expressed
  as a documented authorization contract.
- The module layout is close to the target (one public API followed by private
  helpers) but must be inverted so private assembly precedes the documented API.
- The doc describes data assembly but needs explicit behavior for anonymous
  actors, the NSFW-channel switch, search failures, and empty result groups.

## Work

- Keep `load_front_page/3` as the only public API. Confirm `Scope` is necessary
  because image search needs filter/search state; still derive authorization
  solely from its actor/user and document that boundary.
- Audit each homepage section against the corresponding context's actor-scoped
  loader. Do not maintain a second visibility rule for comments, galleries,
  channels, or watched images in this aggregator.
- Decide whether one failed search section fails the whole page or yields an
  empty section, encode a named result contract, and test it. Do not rescue
  parser/OpenSearch errors ad hoc.
- Move private section/query helpers before `load_front_page/3`; add a spec and
  examples for anonymous and authenticated calls.

## Verification

- Cover anonymous, ordinary-user/filter, watched-tags, and NSFW-channel cases in
  `activities_test.exs` and `activity_controller_test.exs`.
- Re-run affected Images/Galleries/Channels tests after delegating visibility.
