defmodule Philomena.Images.Display.SourcesForm do
  use Ecto.Schema
  import Ecto.Changeset

  alias Philomena.Images.Display.SourceEntryForm

  @type t :: %__MODULE__{}

  embedded_schema do
    embeds_many :old_sources, SourceEntryForm
    embeds_many :sources, SourceEntryForm
  end

  @doc false
  def changeset(%__MODULE__{} = form, attrs \\ %{}) do
    form
    |> cast(attrs, [])
    |> cast_embed(:old_sources)
    |> cast_embed(:sources)
  end
end
