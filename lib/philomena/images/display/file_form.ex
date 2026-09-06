defmodule Philomena.Images.Display.FileForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
  end

  @doc false
  def changeset(file_form, attrs \\ %{}) do
    cast(file_form, attrs, [])
  end
end
