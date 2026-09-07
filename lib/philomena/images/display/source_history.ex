defmodule Philomena.Images.Display.SourceHistory do
  @moduledoc """
  Presentation data for an image's source history destruction control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(source_history, attrs \\ %{}) do
    cast(source_history, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
