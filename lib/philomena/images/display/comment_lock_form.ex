defmodule Philomena.Images.Display.CommentLockForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :comments_locked, :boolean
  end

  @doc false
  def changeset(comment_lock_form, attrs \\ %{}) do
    comment_lock_form
    |> cast(attrs, [:comments_locked])
    |> validate_required([:comments_locked])
  end
end
