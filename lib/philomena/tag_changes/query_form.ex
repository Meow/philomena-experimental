defmodule Philomena.TagChanges.QueryForm do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @sort_fields [:created_at, :tag_count, :added_tag_count, :removed_tag_count]

  @type t :: %__MODULE__{}

  embedded_schema do
    field :tcq, :string, default: "*"
    field :sf, Ecto.Enum, values: @sort_fields, default: :created_at
    field :sd, Ecto.Enum, values: [:asc, :desc], default: :desc
    field :compiled_query, :map, virtual: true
  end

  @doc false
  def changeset(%__MODULE__{} = query_form, attrs \\ %{}) do
    cast(query_form, attrs, [:tcq, :sf, :sd])
  end
end
