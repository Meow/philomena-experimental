defmodule Philomena.Images.Display.UploaderInput do
  @moduledoc """
  Presentation data for an image's uploader input control.

  Contains the username of the current uploader, including the name of
  anonymously-attributed uploaders, or `nil` if the upload was not created
  by any user.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Philomena.Images.Image

  @type t :: %__MODULE__{}
  @primary_key false

  embedded_schema do
    field :username, :string
  end

  @doc false
  def changeset(uploader, attrs \\ %{}) do
    cast(uploader, attrs, [:username])
  end

  @doc false
  def render(%Image{user: user}) do
    if user do
      %__MODULE__{username: user.name}
    else
      %__MODULE__{username: nil}
    end
  end
end
