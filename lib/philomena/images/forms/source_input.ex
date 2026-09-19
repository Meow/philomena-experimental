defmodule Philomena.Images.Forms.SourceInput do
  @moduledoc """
  Presentation data for an image's source input control.

  Contains the current source list.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Philomena.Images.Forms
  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    embeds_many :old_sources, Forms.Source, on_replace: :delete
    embeds_many :sources, Forms.Source, on_replace: :delete
  end

  @doc false
  def changeset(source_input, attrs \\ %{}) do
    source_input
    |> cast(attrs, [])
    |> cast_embed(:old_sources)
    |> cast_embed(:sources)
    |> ensure_source()
  end

  @doc false
  def render(%Image{sources: sources}) do
    sources = Enum.map(sources, &Forms.Source.render/1)

    %__MODULE__{
      old_sources: sources,
      sources: sources
    }
  end

  defp ensure_source(%Ecto.Changeset{} = changeset) do
    # Empty sources are dropped on submission. One source is provided if none
    # are in the list to ensure the client has something to work with.
    if get_field(changeset, :sources) == [] do
      put_embed(changeset, :sources, [Forms.Source.changeset(%Forms.Source{})])
    else
      changeset
    end
  end
end
