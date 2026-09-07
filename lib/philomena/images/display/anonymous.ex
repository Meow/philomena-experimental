defmodule Philomena.Images.Display.Anonymous do
  @moduledoc """
  Presentation data for an image's anonymity control.

  Contains the `anonymous` value.

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
    field :anonymous, :boolean
  end

  @doc false
  def changeset(anonymous, attrs \\ %{}) do
    anonymous
    |> cast(attrs, [:anonymous])
    |> validate_required(:anonymous)
  end

  @doc false
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :update_anonymous, image) do
      %__MODULE__{anonymous: image.anonymous}
    end
  end
end
