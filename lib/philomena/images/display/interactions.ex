defmodule Philomena.Images.Display.Interactions do
  @moduledoc """
  Presentation data for image interactions.
  """

  alias Philomena.Images.Display.FaveInteraction
  alias Philomena.Images.Display.HideInteraction
  alias Philomena.Images.Display.VoteInteraction

  @enforce_keys [
    :faved?,
    :faves_count,
    :upvoted?,
    :upvotes_count,
    :score,
    :downvoted?,
    :downvotes_count,
    :hidden?,
    :hides_count,
    :fave_changeset,
    :hide_changeset,
    :vote_changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          faved?: boolean(),
          faves_count: non_neg_integer(),
          upvoted?: boolean(),
          upvotes_count: non_neg_integer(),
          score: integer(),
          downvoted?: boolean(),
          downvotes_count: non_neg_integer(),
          hidden?: boolean(),
          hides_count: non_neg_integer(),
          fave_changeset: Ecto.Changeset.t(FaveInteraction.t()) | nil,
          hide_changeset: Ecto.Changeset.t(HideInteraction.t()) | nil,
          vote_changeset: Ecto.Changeset.t(VoteInteraction.t()) | nil
        }
end
