defmodule Philomena.Images.Display.Uploader do
  @moduledoc """
  Presentation data for an image's uploader.

  Contains the attribution of the image's uploader.
  """

  alias Philomena.Attribution.Display.Attribution
  alias Philomena.Attribution.Display.IdentityMetadata

  @enforce_keys [:identity_metadata, :uploader]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          identity_metadata: IdentityMetadata.t() | nil,
          uploader: Attribution.t()
        }
end
