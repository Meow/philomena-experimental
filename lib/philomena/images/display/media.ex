defmodule Philomena.Images.Display.Media do
  @moduledoc """
  Presentation data for an image's media paths.
  """

  @enforce_keys [:tag_suffix, :thumbnail_paths, :rendered?, :optimized?, :duplication_checked?]
  defstruct @enforce_keys

  @type thumbnail_paths :: %{
          optional(:mp4) => String.t(),
          optional(:webm) => String.t(),
          full: String.t(),
          tall: String.t(),
          large: String.t(),
          medium: String.t(),
          small: String.t(),
          thumb: String.t(),
          thumb_small: String.t(),
          thumb_tiny: String.t()
        }

  @type t :: %__MODULE__{
          tag_suffix: String.t(),
          thumbnail_paths: :not_rendered | {:thumbnail_paths, thumbnail_paths()},
          rendered?: boolean(),
          optimized?: boolean()
        }
end
