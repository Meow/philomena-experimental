defmodule Philomena.Images.Display.Hash do
  @moduledoc """
  Presentation data for an image's hash removal control.

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
  def changeset(hash, attrs \\ %{}) do
    cast(hash, attrs, [])
  end

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :remove_hash, image) do
      %__MODULE__{}
    end
  end
end
