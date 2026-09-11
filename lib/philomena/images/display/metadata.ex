defmodule Philomena.Images.Display.Metadata do
  @moduledoc """
  Presentation data for image metadata.
  """

  alias Philomena.Images.Image

  @enforce_keys [
    :id,
    :created_at,
    :updated_at,
    :first_seen_at,
    :aspect_ratio,
    :width,
    :height,
    :duration,
    :format,
    :mime_type,
    :size,
    :original_size,
    :sha512_hash,
    :original_sha512_hash,
    :filename,
    :animated?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: integer(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          first_seen_at: DateTime.t(),
          aspect_ratio: float(),
          width: pos_integer(),
          height: pos_integer(),
          duration: float(),
          format: String.t(),
          mime_type: String.t(),
          size: non_neg_integer(),
          original_size: non_neg_integer(),
          sha512_hash: String.t() | nil,
          original_sha512_hash: String.t() | nil,
          filename: String.t() | nil,
          animated?: boolean()
        }

  def render(%Image{} = image) do
    %__MODULE__{
      id: image.id,
      created_at: image.created_at,
      updated_at: image.updated_at,
      first_seen_at: image.first_seen_at,
      aspect_ratio: image.image_aspect_ratio,
      width: image.image_width,
      height: image.image_height,
      duration: if(image.image_is_animated, do: image.image_duration, else: 0.0),
      format: image.image_format,
      mime_type: image.image_mime_type,
      size: image.image_size,
      original_size: image.image_orig_size,
      sha512_hash: image.image_sha512_hash,
      original_sha512_hash: image.image_orig_sha512_hash,
      filename: image.image_name,
      animated?: image.image_is_animated
    }
  end
end
