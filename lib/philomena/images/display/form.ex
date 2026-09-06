defmodule Philomena.Images.Display.Form do
  use Ecto.Schema
  import Ecto.Changeset

  alias Philomena.Images.Display.SourceEntryForm

  @type t :: %__MODULE__{}

  embedded_schema do
    embeds_many :sources, SourceEntryForm

    field :anonymous, :boolean
    field :description, :string
    field :source_url, :string
    field :tag_input, :string
  end

  @doc false
  def changeset(form, attrs \\ %{}) do
    form
    |> cast(attrs, [:anonymous, :description, :source_url, :tag_input])
    |> cast_embed(:sources)
    |> validate_length(:description, max: 50_000, count: :bytes)
    |> validate_format(:source_url, ~r/\Ahttps?:\/\//)
  end
end
