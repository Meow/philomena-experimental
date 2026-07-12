defmodule Philomena.Images.ImagePage do
  @moduledoc """
  Everything the image page shows for one viewer: the image, the visible
  page of its comments, the viewer's subscription state and interactions,
  the viewer's galleries paired with whether they already contain the image,
  and the changesets backing the comment and metadata-edit forms.

  Comment and description bodies are carried raw; rendering them is the
  caller's concern.
  """

  alias Philomena.Images.Image

  @enforce_keys [
    :image,
    :comments,
    :watching,
    :user_galleries,
    :interactions,
    :comment_changeset,
    :image_changeset
  ]
  defstruct [
    :image,
    :comments,
    :watching,
    :user_galleries,
    :interactions,
    :comment_changeset,
    :image_changeset
  ]

  @type t :: %__MODULE__{
          image: Image.t(),
          comments: Scrivener.Page.t(),
          watching: boolean(),
          user_galleries: [{Philomena.Galleries.Gallery.t(), boolean()}],
          interactions: list(),
          comment_changeset: Ecto.Changeset.t(),
          image_changeset: Ecto.Changeset.t()
        }
end
