defmodule Philomena.Images.Display.File do
  @moduledoc """
  Presentation data for an image's file replacement control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(file, attrs \\ %{}) do
    cast(file, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
