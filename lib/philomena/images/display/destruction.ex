defmodule Philomena.Images.Display.Destruction do
  @moduledoc """
  Presentation data for an image's destruction control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(destruction, attrs \\ %{}) do
    cast(destruction, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
