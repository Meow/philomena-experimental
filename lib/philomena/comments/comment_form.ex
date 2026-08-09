defmodule Philomena.Comments.CommentForm do
  @moduledoc """
  An editable comment together with the changeset rendered by its form.
  """

  alias Philomena.Comments.Comment

  @enforce_keys [:comment, :changeset]
  defstruct [:comment, :changeset]

  @type t :: %__MODULE__{
          comment: Comment.t(),
          changeset: Ecto.Changeset.t()
        }
end
