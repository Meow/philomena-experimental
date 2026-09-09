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

  @type interaction_count ::
          :hidden | {:count, integer()}

  @type t :: %__MODULE__{
          faved?: boolean(),
          faves_count: interaction_count(),
          upvoted?: boolean(),
          upvotes_count: interaction_count(),
          score: interaction_count(),
          downvoted?: boolean(),
          downvotes_count: interaction_count(),
          hidden?: boolean(),
          hides_count: interaction_count(),
          fave_changeset: Ecto.Changeset.t(FaveInteraction.t()) | nil,
          hide_changeset: Ecto.Changeset.t(HideInteraction.t()) | nil,
          vote_changeset: Ecto.Changeset.t(VoteInteraction.t()) | nil
        }

  @doc false
  def redact_interaction_counts(%__MODULE__{} = interactions, may_reveal_vote_counts?) do
    # Interaction counts are never sensitive information (anonymous actors can see them)
    # This is simply a convenience to avoid a function with many parameters
    if may_reveal_vote_counts? do
      interactions
    else
      %{interactions | upvotes_count: :hidden, downvotes_count: :hidden}
    end
  end
end
