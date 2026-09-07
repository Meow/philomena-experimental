defmodule Philomena.Images.Display.DescriptionLock do
  @moduledoc """
  Presentation data for an image's description lock control.

  Contains whether the description is currently locked.

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
    field :description_locked, :boolean
  end

  @doc false
  def changeset(description_lock, attrs \\ %{}) do
    description_lock
    |> cast(attrs, [:description_locked])
    |> validate_required([:description_locked])
  end

  @doc false
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :lock_description, image) do
      %__MODULE__{description_locked: not image.description_editing_allowed}
    end
  end
end
