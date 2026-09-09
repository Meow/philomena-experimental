defmodule Philomena.Images.Display.Image do
  @moduledoc """
  Presentation data for the image creation form.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Philomena.Images.Display.Source

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    embeds_many :sources, Source

    field :anonymous, :boolean
    field :description, :string
    field :source_url, :string
    field :tag_input, :string
  end

  @doc false
  def changeset(image, attrs \\ %{}) do
    image
    |> cast(attrs, [:anonymous, :description, :source_url, :tag_input])
    |> cast_embed(:sources)
    |> validate_length(:description, max: 50_000, count: :bytes)
    |> validate_format(:source_url, ~r/\Ahttps?:\/\//)
  end
end
