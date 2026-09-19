defmodule Philomena.Images.Display.Tags do
  @moduledoc """
  Presentation data for an image's tags area.
  """

  alias Philomena.Images.Forms
  alias Philomena.Images.Image
  alias Philomena.Tags

  @enforce_keys [
    :tag_changes_count,
    :tag_change_tags_count,
    :tags,
    :locked_tags,
    :changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tag_changes_count: non_neg_integer(),
          tag_change_tags_count: non_neg_integer(),
          tags: [Tags.Display.Tag.t()],
          locked_tags: [Tags.Display.Tag.t()],
          changeset: Ecto.Changeset.t(Forms.TagInput.t()) | nil
        }

  @doc false
  def render(
        %Image{tags: tags, locked_tags: locked_tags},
        tag_changes_count,
        tag_change_tags_count,
        tag_input_changeset
      ) do
    tags = Tags.Tag.display_order(tags)
    locked_tags = Tags.Tag.display_order(locked_tags)

    %__MODULE__{
      tag_changes_count: tag_changes_count,
      tag_change_tags_count: tag_change_tags_count,
      tags: Enum.map(tags, &Tags.Display.Tag.render/1),
      locked_tags: Enum.map(locked_tags, &Tags.Display.Tag.render/1),
      changeset: tag_input_changeset
    }
  end
end
