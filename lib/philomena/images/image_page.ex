defmodule Philomena.Images.ImagePage do
  @moduledoc """
  The per-viewer data gathered for one image: the image, the visible
  page of its comments, the viewer's subscription state and interactions,
  the viewer's galleries paired with whether they already contain the image,
  and changesets for each action available on the page.

  Comment and description bodies are carried in their raw form.
  """

  alias Philomena.Images.Image

  @enforce_keys [
    :image,
    :comments,
    :watching,
    :can_interact,
    :user_galleries,
    :interactions,
    :description,
    :tags,
    :sources,
    :comment_changeset,
    :file_changeset,
    :hide_changeset,
    :feature_changeset,
    :repair_changeset,
    :hash_changeset,
    :source_history_changeset,
    :uploader_changeset,
    :anonymous_changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          image: Image.t(),
          comments: Scrivener.Page.t(),
          watching: boolean(),
          can_interact: boolean(),
          user_galleries: [{Philomena.Galleries.Gallery.t(), boolean()}],
          interactions: list(),
          description: Philomena.Images.Display.Description.t(),
          tags: Philomena.Images.Display.Tags.t(),
          sources: Philomena.Images.Display.Sources.t(),
          comment_changeset: Ecto.Changeset.t() | nil,
          file_changeset: Ecto.Changeset.t() | nil,
          hide_changeset: Ecto.Changeset.t(Philomena.Images.Display.Hide.t()) | nil,
          feature_changeset: Ecto.Changeset.t() | nil,
          repair_changeset: Ecto.Changeset.t() | nil,
          hash_changeset: Ecto.Changeset.t() | nil,
          source_history_changeset:
            Ecto.Changeset.t(Philomena.Images.Display.SourceHistory.t()) | nil,
          uploader_changeset: Ecto.Changeset.t(Philomena.Images.Display.Uploader.t()) | nil,
          anonymous_changeset: Ecto.Changeset.t(Philomena.Images.Display.Anonymous.t()) | nil
        }
end
