defmodule Philomena.Images.Display.Hash do
  @moduledoc """
  Presentation data for an image's hash removal control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(hash, attrs \\ %{}) do
    cast(hash, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
