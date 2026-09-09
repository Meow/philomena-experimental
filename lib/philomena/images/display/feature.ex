defmodule Philomena.Images.Display.Feature do
  @moduledoc """
  Presentation data for an image's feature control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(feature, attrs \\ %{}) do
    cast(feature, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
