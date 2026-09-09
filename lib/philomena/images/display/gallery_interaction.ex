defmodule Philomena.Images.Display.GalleryInteraction do
  @moduledoc """
  Presentation data for an image gallery interaction control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(gallery_interaction, attrs \\ %{}) do
    cast(gallery_interaction, attrs, [])
  end
end
