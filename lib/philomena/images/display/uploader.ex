defmodule Philomena.Images.Display.Uploader do
  @moduledoc """
  Presentation data for an image's uploader.

  Contains the attribution of the image's uploader.
  """

  alias Philomena.Attribution

  @enforce_keys [:identity_metadata, :uploader]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          identity_metadata: Attribution.Display.IdentityMetadata.t() | nil,
          uploader: Attribution.Display.Attribution.t()
        }
end
