defmodule Philomena.Images.Display.UploaderForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :username, :string
  end

  @doc false
  def changeset(uploader_form, attrs \\ %{}) do
    cast(uploader_form, attrs, [:username])
  end
end
