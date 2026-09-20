defmodule Philomena.Tags.TagPage do
  @moduledoc """
  The assembled tag page: the tag with its preloads, the executed
  page of image previews tagged with it and the escaped search query that
  lists the tag.

  The tag carries raw records, not rendered output.
  """

  alias Philomena.Images
  alias Philomena.Tags.Tag

  @enforce_keys [:tag, :images, :search_query]
  defstruct tag: nil,
            images: nil,
            search_query: nil

  @type t :: %__MODULE__{
          tag: Tag.t(),
          images: Scrivener.Page.t(Images.Display.Preview.t()),
          search_query: String.t()
        }
end
