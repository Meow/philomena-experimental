defmodule Philomena.Images.Display.Comments do
  @moduledoc """
  Presentation data for a page of image comments.
  """

  @enforce_keys [:comments_count, :comments, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          comments_count: non_neg_integer(),
          # TODO(presentation-split)
          comments: Scrivener.Page.t(Philomena.Comments.Comment.t()),
          changeset: Ecto.Changeset.t(Philomena.Comments.Comment.t()) | nil
        }
end
