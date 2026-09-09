defmodule Philomena.Images.Display.GalleryChoice do
  @moduledoc """
  Presentation data for an image gallery choice control.
  """

  alias Philomena.Images.Display.GalleryInteraction

  @enforce_keys [:name, :id, :present?, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          id: integer(),
          present?: boolean(),
          changeset: Ecto.Changeset.t(GalleryInteraction.t()) | nil
        }
end
