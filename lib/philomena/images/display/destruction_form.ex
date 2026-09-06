defmodule Philomena.Images.Display.DestructionForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
  end

  @doc false
  def changeset(destruction_form, attrs \\ %{}) do
    cast(destruction_form, attrs, [])
  end
end
