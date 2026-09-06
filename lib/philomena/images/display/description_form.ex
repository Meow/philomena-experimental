defmodule Philomena.Images.Display.DescriptionForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :description
  end

  @doc false
  def changeset(description_form, attrs \\ %{}) do
    cast(description_form, attrs, [:description])
  end
end
