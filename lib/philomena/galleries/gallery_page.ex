defmodule Philomena.Galleries.GalleryPage do
  @moduledoc """
  Everything the gallery page needs for one viewer: the gallery, the
  visible page of its image previews, the previews on
  the adjacent pages folded into one ordered list, whether
  those adjacent pages exist, and the viewer's subscription state. Each image
  preview carries the viewer's interaction state.

  `gallery_images` is the concatenation of the previous page, this page, and
  the next page, each entry carrying its sort cursor; `gallery_prev` and
  `gallery_next` report only whether those neighbouring pages hold anything.
  """

  alias Philomena.Galleries.Gallery
  alias Philomena.Images

  @enforce_keys [
    :gallery,
    :images,
    :gallery_images,
    :gallery_prev,
    :gallery_next,
    :watching
  ]
  defstruct [
    :gallery,
    :images,
    :gallery_images,
    :gallery_prev,
    :gallery_next,
    :watching
  ]

  @type t :: %__MODULE__{
          gallery: Gallery.t(),
          images: Scrivener.Page.t(Images.Display.Preview.t()),
          gallery_images: [Images.Display.Preview.t()],
          gallery_prev: boolean(),
          gallery_next: boolean(),
          watching: boolean()
        }
end
