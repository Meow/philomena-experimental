defmodule Philomena.Images.Display.Anonymous do
  @moduledoc """
  Presentation data for an image's anonymity control.

  Contains the `anonymous` value.
  """

  use Ecto.Schema

  import Ecto.Changeset

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
  def render(%Image{} = image) do
    %__MODULE__{anonymous: image.anonymous}
  end
end
