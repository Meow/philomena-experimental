defmodule Philomena.Images.Display.Approval do
  @moduledoc """
  Presentation data for an image's approval control.

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
  def changeset(approval, attrs \\ %{}) do
    cast(approval, attrs, [])
  end

  @doc false
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :approve, image) and not image.approved do
      %__MODULE__{}
    end
  end
end
