defmodule Philomena.Images.Display.Description do
  @moduledoc """
  Presentation data for an image's description edit control.

  Contains the raw description.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :description
  end

  @doc false
  def changeset(description, attrs \\ %{}) do
    cast(description, attrs, [:description])
  end

  @doc false
  def render(%Image{} = image) do
    %__MODULE__{description: image.description}
  end
end
