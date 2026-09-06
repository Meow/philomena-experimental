defmodule Philomena.Images.Display.SourceHistoryForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
  end

  @doc false
  def changeset(source_history_form, attrs \\ %{}) do
    cast(source_history_form, attrs, [])
  end
end
