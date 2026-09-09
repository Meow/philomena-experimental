defmodule Philomena.Images.Display.Description do
  @moduledoc """
  Presentation data for an image's description.

  Contains the image's description.
  """

  alias Philomena.Images.Display.DescriptionInput
  alias Philomena.Images.Image

  @enforce_keys [:body, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          body: String.t(),
          changeset: Ecto.Changeset.t(DescriptionInput.t()) | nil
        }

  @doc false
  def render(%Image{description: description}, changeset) do
    %__MODULE__{body: description, changeset: changeset}
  end
end
