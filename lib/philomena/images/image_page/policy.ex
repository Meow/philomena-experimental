defmodule Philomena.Images.ImagePage.Policy do
  @moduledoc """
  Viewer-specific disclosure and action capabilities for an image page.
  """

  @enforce_keys [
    :can_interact?,
    :can_manage?,
    :can_hide?,
    :can_unhide?,
    :can_approve?,
    :can_destroy?,
    :can_replace_file?,
    :can_feature?,
    :can_repair?,
    :can_clear_hash?,
    :can_edit_uploader?,
    :can_view_identity_metadata?,
    :can_lock_comments?,
    :can_lock_description?,
    :can_lock_tags?,
    :can_edit_scratchpad?,
    :can_remove_source_history?,
    :can_report?,
    :can_subscribe?,
    :can_manage_galleries?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          can_interact?: boolean(),
          can_manage?: boolean(),
          can_hide?: boolean(),
          can_unhide?: boolean(),
          can_approve?: boolean(),
          can_destroy?: boolean(),
          can_replace_file?: boolean(),
          can_feature?: boolean(),
          can_repair?: boolean(),
          can_clear_hash?: boolean(),
          can_edit_uploader?: boolean(),
          can_view_identity_metadata?: boolean(),
          can_lock_comments?: boolean(),
          can_lock_description?: boolean(),
          can_lock_tags?: boolean(),
          can_edit_scratchpad?: boolean(),
          can_remove_source_history?: boolean(),
          can_report?: boolean(),
          can_subscribe?: boolean(),
          can_manage_galleries?: boolean()
        }
end
