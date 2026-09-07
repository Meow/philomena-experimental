defmodule Philomena.Images.Display.TagsLock do
  @moduledoc """
  Presentation data for an image's tags lock control.

  Contains whether the tags are currently locked.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :tags_locked, :boolean
  end

  @doc false
  def changeset(tags_lock_form, attrs \\ %{}) do
    tags_lock_form
    |> cast(attrs, [:tags_locked])
    |> validate_required([:tags_locked])
  end

  @doc false
  def render(%Image{} = image) do
    %__MODULE__{tags_locked: not image.tag_editing_allowed}
  end
end
