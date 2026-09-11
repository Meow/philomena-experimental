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
  def render(%Image{} = image, may_reveal_description_on_hidden_image?, changeset) do
    body =
      if not image.hidden_from_users or may_reveal_description_on_hidden_image? do
        image.description
      else
        ""
      end

    %__MODULE__{body: body, changeset: changeset}
  end
end
