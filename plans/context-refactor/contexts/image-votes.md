# ImageVotes context plan

Source: `lib/philomena/image_votes.ex`; aggregate owner: `Philomena.Images`.

## Findings

- The module exposes create/delete transaction builders; Images owns actor
  loading, interaction guards, user/image counters, and controller behavior.
- Vote direction changes and repeated requests can make counter invariants more
  complex than the tiny public API suggests.

## Work

- Retain only a narrow internal Multi API or fold it into Images after inventory.
  Require loaded image/user and a validated vote direction; state that this is
  not an authorization boundary.
- Define one transaction contract for new vote, direction replacement, and
  deletion, including score and user vote counters. Make retries idempotent.
- Keep raw IDs and actor checks exclusively in Images and document Multi change
  names/result shapes if composition requires the module to remain public.

## Verification

- Exercise up-to-down/down-to-up transitions, duplicates, deletes, and counter
  invariants here; exercise permissions and malformed image IDs through Images.
