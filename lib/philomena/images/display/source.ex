defmodule Philomena.Images.Display.Source do
  @moduledoc """
  Presentation data for an image source control.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Philomena.Images.Source

  @type t :: %__MODULE__{}
  @primary_key false

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

  @doc false
  def render(%Source{source: source}) do
    %__MODULE__{source: source}
  end

  defp ignore_if_blank(%{valid?: false, changes: changes} = changeset) when changes == %{},
    do: %{changeset | action: :ignore}

  defp ignore_if_blank(changeset),
    do: changeset
end
