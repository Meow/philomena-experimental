defmodule Philomena.Comments.CommentForm do
  @moduledoc """
  An editable comment together with the changeset rendered by its form.
  """

  alias Philomena.Images.Image
  alias Philomena.Comments.Comment

  @enforce_keys [:image, :comment, :changeset]
  defstruct [:image, :comment, :changeset]

  @type t :: %__MODULE__{
          image: Image.t(),
          comment: Comment.t(),
          changeset: Ecto.Changeset.t()
        }
end
