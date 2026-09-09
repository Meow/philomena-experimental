defmodule Philomena.Images.Display.VoteInteraction do
  @moduledoc """
  Presentation data for an image's vote interaction control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :up, :boolean
  end

  @doc false
  def changeset(vote_interaction, attrs) do
    vote_interaction
    |> cast(attrs, [:up])
    |> validate_required([:up])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
