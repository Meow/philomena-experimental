defmodule Philomena.Images.Display.File do
  @moduledoc """
  Presentation data for an image's file replacement control.

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
  def changeset(file, attrs \\ %{}) do
    cast(file, attrs, [])
  end

  @doc false
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :replace_file, image) do
      %__MODULE__{}
    end
  end
end
