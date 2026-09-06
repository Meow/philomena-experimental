defmodule Philomena.Images.Display.HashForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
  end

  @doc false
  def changeset(hash_form, attrs \\ %{}) do
    cast(hash_form, attrs, [])
  end
end
