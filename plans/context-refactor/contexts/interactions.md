# Interactions context plan

Source: `lib/philomena/interactions.ex`; consumers: image JSON/search/related
rendering and image-merge orchestration.

## Findings

- `user_interactions/2` accepts `nil`, Actor, or User, unlike the actor-first
  boundary requested elsewhere. It is read-only personalization, but callers can
  easily choose different conventions.
- `migrate_interactions/2` is a powerful loaded-record modifier with no actor; it
  belongs to an authorized image merge service rather than a controller.
- The module lacks a moduledoc and specs, and public functions precede private
  query helpers.

## Work

- Choose one public controller-facing signature using Actor (anonymous Actor
  yields an empty map/list). If internal serializers need User/nil, hide that
  overload behind a private function.
- Return a typed interaction map keyed by image ID rather than loosely described
  maps if that matches consumers; document omission semantics for no interaction.
- Make migration a narrowly documented image-merge service accepting loaded
  source/target images and state that authorization must occur in Images, or move
  it into Images entirely. Preserve all counters transactionally and define
  conflict precedence when a user interacted with both images.
- Move union/flatten/migration mechanics before public APIs and add specs/docs in
  the requested description/unexpected/examples order.

## Verification

- Test nested/duplicate/nil image inputs, anonymous and actor reads, and all
  source/target interaction collision combinations during merge.
