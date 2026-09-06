defmodule Philomena.Images.Display.LockedTagsForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :tag_input, :string
  end

  @doc false
  def changeset(locked_tags_form, attrs \\ %{}) do
    cast(locked_tags_form, attrs, [:tag_input])
  end
end
