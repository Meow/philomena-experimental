defmodule Philomena.Images.Display.Galleries do
  @moduledoc """
  Presentation data for the image page gallery menu.
  """

  alias Philomena.Images.Display.GalleryChoice

  @enforce_keys [:choices, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          choices: [GalleryChoice.t()],
          # TODO(presentation-split)
          changeset: Ecto.Changeset.t(Philomena.Galleries.Gallery.t())
        }
end
