defmodule Philomena.Images.Display.Hide do
  @moduledoc """
  Presentation data for an image's staff hide control.

  Contains the current hide reason.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :deletion_reason, :string
  end

  @doc false
  def changeset(hide, attrs \\ %{}) do
    hide
    |> cast(attrs, [:deletion_reason])
    |> validate_required([:deletion_reason])
  end

  @doc false
  def render(%Image{} = image) do
    %__MODULE__{deletion_reason: image.deletion_reason}
  end
end
