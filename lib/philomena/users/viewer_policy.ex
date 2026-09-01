defmodule Philomena.Users.ViewerPolicy do
  @moduledoc """
  Viewer-wide capabilities calculated by `Philomena.Users`.

  These values are limited to capabilities that are useful across
  otherwise unrelated pages.
  """

  @enforce_keys [
    :signed_in?,
    :can_batch_update_tags?,
    :can_hide_images?,
    :can_access_staff_settings?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          signed_in?: boolean(),
          can_batch_update_tags?: boolean(),
          can_hide_images?: boolean(),
          can_access_staff_settings?: boolean()
        }
end
