defmodule Philomena.Images.Display.HideInteraction do
  @moduledoc """
  Presentation data for an image's hide interaction control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(hide_interaction, attrs) do
    cast(hide_interaction, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
