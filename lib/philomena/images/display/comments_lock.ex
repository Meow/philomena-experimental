defmodule Philomena.Images.Display.CommentsLock do
  @moduledoc """
  Presentation data for an image's comments lock control.

  Contains whether comments are currently locked.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :comments_locked, :boolean
  end

  @doc false
  def changeset(comment_lock, attrs \\ %{}) do
    comment_lock
    |> cast(attrs, [:comments_locked])
    |> validate_required([:comments_locked])
  end

  @doc false
  def render(%Image{} = image) do
    %__MODULE__{comments_locked: not image.commenting_allowed}
  end
end
