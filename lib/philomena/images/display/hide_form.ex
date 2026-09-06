defmodule Philomena.Images.Display.HideForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :deletion_reason, :string
  end

  @doc false
  def changeset(hide_form, attrs \\ %{}) do
    hide_form
    |> cast(attrs, [:deletion_reason])
    |> validate_required([:deletion_reason])
  end
end
