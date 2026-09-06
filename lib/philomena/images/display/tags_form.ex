defmodule Philomena.Images.Display.TagsForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :old_tag_input, :string
    field :tag_input, :string
  end

  @doc false
  def changeset(tags_form, attrs \\ %{}) do
    tags_form
    |> cast(attrs, [:old_tag_input, :tag_input])
    |> validate_required([:tag_input])
  end
end
