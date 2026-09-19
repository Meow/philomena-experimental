defmodule Philomena.Images.Forms.LockedTags do
  @moduledoc """
  Presentation data for an image's locked tags control.

  Contains the current list of locked tags.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image
  alias Philomena.Tags

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
  def render(%Image{locked_tags: locked_tags}) do
    tag_input =
      locked_tags
      |> Tags.Tag.display_order()
      |> Enum.map_join(", ", & &1.name)

    %__MODULE__{tag_input: tag_input}
  end
end
