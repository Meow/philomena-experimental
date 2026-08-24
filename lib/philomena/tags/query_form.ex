defmodule Philomena.Tags.QueryForm do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :query, :string
    field :compiled_query, :map, virtual: true
  end

  @doc false
  def changeset(%__MODULE__{} = query_form, attrs \\ %{}) do
    cast(query_form, attrs, [:query])
  end
end
