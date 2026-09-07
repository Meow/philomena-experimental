defmodule Philomena.Images.Display.Description do
  @moduledoc """
  Presentation data for an image's description edit control.

  Contains the raw description.

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
    field :description
  end

  @doc false
  def changeset(description, attrs \\ %{}) do
    cast(description, attrs, [:description])
  end

  @doc false
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :edit_description, image) do
      %__MODULE__{description: image.description}
    end
  end
end
