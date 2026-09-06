defmodule Philomena.Images.Display.TagsLockForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :tags_locked, :boolean
  end

  @doc false
  def changeset(tags_lock_form, attrs \\ %{}) do
    tags_lock_form
    |> cast(attrs, [:tags_locked])
    |> validate_required([:tags_locked])
  end
end
