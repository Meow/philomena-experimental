defmodule Philomena.Images.Display.DescriptionLockForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :description_locked, :boolean
  end

  @doc false
  def changeset(description_lock_form, attrs \\ %{}) do
    description_lock_form
    |> cast(attrs, [:description_locked])
    |> validate_required([:description_locked])
  end
end
