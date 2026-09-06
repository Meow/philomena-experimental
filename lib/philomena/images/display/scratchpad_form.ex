defmodule Philomena.Images.Display.ScratchpadForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :scratchpad, :string
  end

  @doc false
  def changeset(scratchpad_form, attrs \\ %{}) do
    cast(scratchpad_form, attrs, [:scratchpad])
  end
end
