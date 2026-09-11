defmodule Philomena.Images.Display.Interactions do
  @moduledoc """
  Presentation data for image interactions.
  """

  alias Philomena.Images.Display.FaveInteraction
  alias Philomena.Images.Display.HideInteraction
  alias Philomena.Images.Display.VoteInteraction
  alias Philomena.Images.Image

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
  def render(%Image{} = image, state, may_reveal_vote_counts?, controls) do
    %__MODULE__{
      faved?: state.faved?,
      faves_count: render_count(image.faves_count, true),
      upvoted?: state.upvoted?,
      upvotes_count: render_count(image.upvotes_count, may_reveal_vote_counts?),
      score: render_count(image.score, true),
      downvoted?: state.downvoted?,
      downvotes_count: render_count(image.downvotes_count, may_reveal_vote_counts?),
      hidden?: state.hidden?,
      hides_count: render_count(image.hides_count, true),
      fave_changeset: controls.fave_changeset,
      hide_changeset: controls.hide_changeset,
      vote_changeset: controls.vote_changeset
    }
  end

  defp render_count(count, revealed?) do
    if revealed? do
      {:count, count}
    else
      :hidden
    end
  end
end
