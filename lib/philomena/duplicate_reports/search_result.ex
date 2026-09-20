defmodule Philomena.DuplicateReports.SearchResult do
  @moduledoc """
  The normalized reverse-image-search result rendered by HTML and JSON callers.

  JSON callers receive image records while HTML callers receive display
  previews.
  """

  alias Philomena.Images

  @enforce_keys [:images, :changeset]
  defstruct [:images, :changeset]

  @type t :: %__MODULE__{
          images: Scrivener.Page.t(Images.Image.t() | Images.Display.Preview.t()) | nil,
          changeset: Ecto.Changeset.t()
        }
end
