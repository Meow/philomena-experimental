defmodule Philomena.Images.Display.Metadata do
  @moduledoc """
  Presentation data for image metadata.
  """

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
          filename: String.t(),
          animated?: boolean()
        }
end
