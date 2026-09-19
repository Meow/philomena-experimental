defmodule Philomena.Images.Display.Description do
  @moduledoc """
  Presentation data for an image's description.

  Contains the image's description.
  """

  alias Philomena.Images.Forms
  alias Philomena.Images.Image

  @enforce_keys [:body, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          body: String.t(),
          changeset: Ecto.Changeset.t(Forms.DescriptionInput.t()) | nil
        }

  @doc false
  def render(%Image{} = image, may_reveal_description_on_hidden_image?, changeset) do
    body =
      if not image.hidden_from_users or may_reveal_description_on_hidden_image? do
        image.description
      else
        # TODO(presentation-split): not present vs not disclosed?
        ""
      end

    %__MODULE__{body: body, changeset: changeset}
  end
end
