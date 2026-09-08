defmodule Philomena.Images.Display.Tags do
  @moduledoc """
  Presentation data for an image's tags area.
  """

  alias Philomena.Images.Display.TagInput
  alias Philomena.Images.Image

  @enforce_keys [
    :tag_change_count,
    :tag_change_tag_count,
    :tags,
    :locked_tags,
    :changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tag_change_count: non_neg_integer(),
          tag_change_tag_count: non_neg_integer(),
          # TODO(presentation-split): this is currently an array of Tag,
          # but it should be an array of the Tag presentation display.
          tags: [Philomena.Tags.Tag.t()],
          locked_tags: [Philomena.Tags.Tag.t()],
          changeset: Ecto.Changeset.t(TagInput.t()) | nil
        }

  @doc false
  def render(
        %Image{tags: tags, locked_tags: locked_tags},
        tag_change_count,
        tag_change_tag_count,
        tag_input_changeset
      ) do
    # TODO(presentation-split): this is to ensure that the associations are loaded
    # Convert to Tag presentation display when ready
    _ = Enum.any?(tags)
    _ = Enum.any?(locked_tags)

    %__MODULE__{
      tag_change_count: tag_change_count,
      tag_change_tag_count: tag_change_tag_count,
      tags: tags,
      locked_tags: locked_tags,
      changeset: tag_input_changeset
    }
  end
end
