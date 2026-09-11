defmodule Philomena.Images.Display.Comments do
  @moduledoc """
  Presentation data for a page of image comments.
  """

  alias Philomena.Images.Image

  @enforce_keys [:comments_count, :comments, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          comments_count: non_neg_integer(),
          # TODO(presentation-split)
          comments: Scrivener.Page.t(Philomena.Comments.Comment.t()),
          changeset: Ecto.Changeset.t(Philomena.Comments.Comment.t()) | nil
        }

  @doc false
  def render(%Image{} = image, may_reveal_comments_on_hidden_image?, comments, changeset) do
    comments =
      if not image.hidden_from_users or may_reveal_comments_on_hidden_image? do
        comments
      else
        %{comments | entries: []}
      end

    %__MODULE__{
      comments_count: image.comments_count,
      comments: comments,
      changeset: changeset
    }
  end
end
