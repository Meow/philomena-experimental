defmodule Philomena.Administration.Navigation do
  @moduledoc """
  Viewer-specific application-shell destinations and queue counts.
  """

  @enforce_keys [
    :can_manage_site_notices?,
    :can_manage_tags?,
    :can_manage_users?,
    :can_manage_forums?,
    :can_manage_adverts?,
    :can_manage_badges?,
    :can_manage_static_pages?,
    :can_manage_mod_notes?,
    :can_view_moderation_log?,
    :can_manage_bans?,
    :can_view_approvals?,
    :can_view_duplicate_reports?,
    :can_view_reports?,
    :can_view_artist_links?,
    :can_view_dnp_entries?,
    :show_admin_menu?,
    :pending_approval_count,
    :duplicate_report_count,
    :report_count,
    :artist_link_count,
    :dnp_entry_count
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          can_manage_site_notices?: boolean(),
          can_manage_tags?: boolean(),
          can_manage_users?: boolean(),
          can_manage_forums?: boolean(),
          can_manage_adverts?: boolean(),
          can_manage_badges?: boolean(),
          can_manage_static_pages?: boolean(),
          can_manage_mod_notes?: boolean(),
          can_view_moderation_log?: boolean(),
          can_manage_bans?: boolean(),
          can_view_approvals?: boolean(),
          can_view_duplicate_reports?: boolean(),
          can_view_reports?: boolean(),
          can_view_artist_links?: boolean(),
          can_view_dnp_entries?: boolean(),
          show_admin_menu?: boolean(),
          pending_approval_count: non_neg_integer() | nil,
          duplicate_report_count: non_neg_integer() | nil,
          report_count: non_neg_integer() | nil,
          artist_link_count: non_neg_integer() | nil,
          dnp_entry_count: non_neg_integer() | nil
        }
end
