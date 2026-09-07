defmodule Philomena.Images.Display.Scratchpad do
  @moduledoc """
  Presentation data for an image's moderation scratchpad control.

  Contains the current moderation scratchpad.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :scratchpad, :string
  end

  @doc false
  def changeset(scratchpad, attrs \\ %{}) do
    cast(scratchpad, attrs, [:scratchpad])
  end

  @doc false
  def render(%Image{} = image) do
    %__MODULE__{scratchpad: image.scratchpad}
  end
end
