defmodule Philomena.Images.Forms.TagInput do
  @moduledoc """
  Presentation data for an image's tag input control.

  Contains the current tag list.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image
  alias Philomena.Tags

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :old_tag_input, :string
    field :tag_input, :string
  end

  @doc false
  def changeset(tags_form, attrs \\ %{}) do
    tags_form
    |> cast(attrs, [:old_tag_input, :tag_input])
    |> validate_required([:tag_input])
  end

  @doc false
  def render(%Image{tags: tags}) do
    tag_input =
      tags
      |> Tags.Tag.display_order()
      |> Enum.map_join(", ", & &1.name)

    %__MODULE__{
      old_tag_input: tag_input,
      tag_input: tag_input
    }
  end
end
