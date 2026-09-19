defmodule Philomena.Images.Display.Page do
  @moduledoc """
  Presentation data for a complete image page.
  """

  alias Philomena.Images.Display

  @enforce_keys [
    :interactions,
    :metadata,
    :subscription,
    :galleries,
    :media,
    :uploader,
    :description,
    :tags,
    :deprecated_tags_with_aliases,
    :sources,
    :moderation,
    :moderation_metadata,
    :comments
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          interactions: Display.Interactions.t(),
          metadata: Display.Metadata.t(),
          subscription: Display.Subscription.t(),
          galleries: Display.Galleries.t(),
          media: Display.Media.t(),
          uploader: Display.Uploader.t(),
          description: Display.Description.t(),
          tags: Display.Tags.t(),
          deprecated_tags_with_aliases: Display.DeprecatedTagsWithAliases.t(),
          sources: Display.Sources.t(),
          moderation: Display.Moderation.t(),
          moderation_metadata: Display.ModerationMetadata.t(),
          comments: Display.Comments.t()
        }
end
