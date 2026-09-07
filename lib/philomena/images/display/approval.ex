defmodule Philomena.Images.Display.Approval do
  @moduledoc """
  Presentation data for an image's approval control.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
  end

  @doc false
  def changeset(approval, attrs \\ %{}) do
    cast(approval, attrs, [])
  end

  @doc false
  def render(%Image{}) do
    %__MODULE__{}
  end
end
