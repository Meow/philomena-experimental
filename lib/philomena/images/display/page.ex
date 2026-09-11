defmodule Philomena.Images.Display.Page do
  @moduledoc """
  Presentation data for a complete image page.
  """

  alias Philomena.Images.Display.{
    Comments,
    Description,
    Galleries,
    Interactions,
    Media,
    Metadata,
    Moderation,
    ModerationMetadata,
    Sources,
    Subscription,
    Tags,
    Uploader
  }

  @enforce_keys [
    :interactions,
    :metadata,
    :subscription,
    :galleries,
    :media,
    :uploader,
    :description,
    :tags,
    :sources,
    :moderation,
    :moderation_metadata,
    :comments
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          interactions: Interactions.t(),
          metadata: Metadata.t(),
          subscription: Subscription.t(),
          galleries: Galleries.t(),
          media: Media.t(),
          uploader: Uploader.t(),
          description: Description.t(),
          tags: Tags.t(),
          sources: Sources.t(),
          moderation: Moderation.t(),
          moderation_metadata: ModerationMetadata.t(),
          comments: Comments.t()
        }
end
