defmodule Philomena.Images.Display.Tags do
  @moduledoc """
  Presentation data for an image's tags area.
  """

  alias Philomena.Images.Image

  @enforce_keys [
    :tag_change_count,
    :tag_change_tag_count,
    :tags,
    :locked_tags
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tag_change_count: non_neg_integer(),
          tag_change_tag_count: non_neg_integer(),
          # TODO(presentation-split): this is currently an array of Tag,
          # but it should be an array of the Tag presentation display.
          tags: [Philomena.Tags.Tag.t()],
          locked_tags: [Philomena.Tags.Tag.t()]
        }

  @doc false
  def render(%Image{} = image, tag_change_count, tag_change_tag_count) do
    # TODO(presentation-split): this is to ensure that the associations are loaded
    # Convert to Tag presentation display when ready
    _ = Enum.any?(image.tags)
    _ = Enum.any?(image.locked_tags)

    %__MODULE__{
      tag_change_count: tag_change_count,
      tag_change_tag_count: tag_change_tag_count,
      tags: image.tags,
      locked_tags: image.locked_tags
    }
  end
end
