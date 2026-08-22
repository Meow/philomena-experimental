defmodule Philomena.TagChanges.TagChangePage do
  @moduledoc """
  A paginated tag-change listing and its independently resolved resource target.

  `target` is `nil` for the global listing. Resource-specific listings carry the
  loaded image, tag, user, canonical IP address, or canonical fingerprint.
  """

  alias Philomena.Images.Image
  alias Philomena.Tags.Tag
  alias Philomena.Users.User

  @type resource_type :: :all | :image | :tag | :user | :ip | :fingerprint
  @type target :: Image.t() | Tag.t() | User.t() | Postgrex.INET.t() | String.t() | nil

  @enforce_keys [:resource_type, :target, :tag_changes]
  defstruct [:resource_type, :target, :tag_changes]

  @type t :: %__MODULE__{
          resource_type: resource_type(),
          target: target(),
          tag_changes: Scrivener.Page.t()
        }
end
