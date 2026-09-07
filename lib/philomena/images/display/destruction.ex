defmodule Philomena.Images.Display.Destruction do
  @moduledoc """
  Presentation data for an image's destruction control.

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
  end

  @doc false
  def changeset(destruction, attrs \\ %{}) do
    cast(destruction, attrs, [])
  end

  @doc false
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :destroy, image) and image.hidden_from_users and
         not image.destroyed_content do
      %__MODULE__{}
    end
  end
end
