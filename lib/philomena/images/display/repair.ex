defmodule Philomena.Images.Display.Repair do
  @moduledoc """
  Presentation data for an image's repair control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(repair, attrs \\ %{}) do
    cast(repair, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
