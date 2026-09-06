defmodule Philomena.Images.Display.AnonymousForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :anonymous, :boolean
  end

  @doc false
  def changeset(anonymous_form, attrs \\ %{}) do
    anonymous_form
    |> cast(attrs, [:anonymous])
    |> validate_required(:anonymous)
  end
end
