defmodule Philomena.Galleries.QueryForm do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :title, :string
    field :creator, :string
    field :include_image, :integer
    field :description, :string
    field :sf, :string, default: "created_at"
    field :sd, :string, default: "desc"
  end

  @doc false
  def changeset(%__MODULE__{} = search_form, attrs \\ %{}) do
    search_form
    |> cast(attrs, [:title, :creator, :include_image, :description, :sf, :sd])
    |> validate_inclusion(:sf, ~w(created_at updated_at image_count subscriber_count _score))
    |> validate_inclusion(:sd, ~w(desc asc))
    |> validate_required([:sf, :sd])
  end
end
