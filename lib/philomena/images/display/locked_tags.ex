defmodule Philomena.Images.Display.LockedTags do
  @moduledoc """
  Presentation data for an image's locked tags control.

  Contains the current list of locked tags.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :tag_input, :string
  end

  @doc false
  def changeset(locked_tags, attrs \\ %{}) do
    cast(locked_tags, attrs, [:tag_input])
  end

  @doc false
  def render(%Image{} = image) do
    %__MODULE__{tag_input: Enum.map_join(image.locked_tags, ", ", & &1.name)}
  end
end
