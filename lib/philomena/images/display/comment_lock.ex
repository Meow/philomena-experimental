defmodule Philomena.Images.Display.CommentLock do
  @moduledoc """
  Presentation data for an image's comment lock control.

  Contains whether comments are currently locked.

  Omitted when the control is unavailable to the actor.
  """

  use Ecto.Schema

  import Philomena.Images.Display.Authorization
  import Ecto.Changeset

  alias Philomena.Attribution.Actor
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
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :lock_comments, image) do
      %__MODULE__{comments_locked: not image.commenting_allowed}
    end
  end
end
