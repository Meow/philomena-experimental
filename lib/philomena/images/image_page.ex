defmodule Philomena.Images.ImagePage do
  @moduledoc """
  The per-viewer data gathered for one image: the image, the visible
  page of its comments, the viewer's subscription state and interactions,
  the viewer's galleries paired with whether they already contain the image,
  and changesets for adding a comment and editing its metadata.

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
    :comment_changeset,
    :image_changeset
  ]
  defstruct [
    :image,
    :comments,
    :watching,
    :can_interact,
    :user_galleries,
    :interactions,
    :comment_changeset,
    :image_changeset
  ]

  @type t :: %__MODULE__{
          image: Image.t(),
          comments: Scrivener.Page.t(),
          watching: boolean(),
          can_interact: boolean(),
          user_galleries: [{Philomena.Galleries.Gallery.t(), boolean()}],
          interactions: list(),
          comment_changeset: Ecto.Changeset.t() | nil,
          image_changeset: Ecto.Changeset.t() | nil
        }
end
