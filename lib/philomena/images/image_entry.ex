defmodule Philomena.Images.ImageEntry do
  @moduledoc """
  An image paired with the viewer-safe media projection.
  """

  alias Philomena.Images.Image
  alias Philomena.Images.Media

  @enforce_keys [:image, :media]
  defstruct [:image, :media]

  @type t :: %__MODULE__{image: Image.t(), media: Media.t()}
end
