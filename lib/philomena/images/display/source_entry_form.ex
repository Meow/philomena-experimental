defmodule Philomena.Images.Display.SourceEntryForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
    field :source, :string
  end

  @doc false
  def changeset(source, attrs \\ %{}) do
    source
    |> cast(attrs, [:source])
    |> validate_required([:source])
    |> validate_format(:source, ~r/\Ahttps?:\/\//)
    |> validate_length(:source, max: 255)
    |> ignore_if_blank()
  end

  defp ignore_if_blank(%{valid?: false, changes: changes} = changeset) when changes == %{},
    do: %{changeset | action: :ignore}

  defp ignore_if_blank(changeset),
    do: changeset
end
