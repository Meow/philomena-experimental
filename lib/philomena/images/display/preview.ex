defmodule Philomena.Images.Display.Preview do
  @moduledoc """
  Presentation data for an image preview: images on a listing page or
  embedded in a communication.
  """

  alias Philomena.Images.Display

  @enforce_keys [
    :cursor,
    :deprecated_tags_with_aliases,
    :filter_or_spoiler_hits?,
    :media,
    :metadata,
    :moderation_metadata,
    :interactions,
    :sources,
    :tags
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          cursor: {:cursor, [number()]} | :none,
          deprecated_tags_with_aliases: Display.DeprecatedTagsWithAliases.t(),
          filter_or_spoiler_hits?: boolean(),
          media: Display.Media.t(),
          metadata: Display.Metadata.t(),
          moderation_metadata: Display.ModerationMetadata.t(),
          interactions: Display.Interactions.t(),
          sources: Display.Sources.t(),
          tags: Display.Tags.t()
        }
end
