defmodule Philomena.Images.Display.FaveInteraction do
  @moduledoc """
  Presentation data for an image's fave interaction control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(fave_interaction, attrs) do
    cast(fave_interaction, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
