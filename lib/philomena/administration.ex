defmodule Philomena.Administration do
  @moduledoc """
  Application-wide administration navigation and queue counters.
  """

  import Philomena.Authorization, only: [permitted?: 3]

  alias Philomena.Administration.Navigation
  alias Philomena.Adverts.Advert
  alias Philomena.Attribution.Actor
  alias Philomena.ArtistLinks
  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.Badges.Badge
  alias Philomena.Bans.User, as: UserBan
  alias Philomena.DnpEntries
  alias Philomena.DnpEntries.DnpEntry
  alias Philomena.DuplicateReports
  alias Philomena.DuplicateReports.DuplicateReport
  alias Philomena.Forums.Forum
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.ModNotes.ModNote
  alias Philomena.Reports
  alias Philomena.Reports.Report
  alias Philomena.SiteNotices.SiteNotice
  alias Philomena.StaticPages.StaticPage
  alias Philomena.Tags.Tag
  alias Philomena.Users.User

  @management_destination_keys [
    :can_manage_site_notices?,
    :can_manage_tags?,
    :can_manage_users?,
    :can_manage_forums?,
    :can_manage_adverts?,
    :can_manage_badges?,
    :can_manage_static_pages?,
    :can_manage_mod_notes?,
    :can_manage_bans?
  ]

  @doc """
  Returns the application shell destinations and queue counts for `actor`.

  Queue counts are `nil` when their destination is unavailable.

  ## Example

      iex> navigation = show_navigation(actor)

  """
  @spec show_navigation(Actor.t()) :: Navigation.t()
  def show_navigation(%Actor{user: user} = actor) do
    navigation = %Navigation{
      can_manage_site_notices?: permitted?(user, :index, SiteNotice),
      can_manage_tags?: permitted?(user, :edit, %Tag{}),
      can_manage_users?: permitted?(user, :index, User),
      can_manage_forums?: permitted?(user, :edit, Forum),
      can_manage_adverts?: permitted?(user, :index, Advert),
      can_manage_badges?: permitted?(user, :index, Badge),
      can_manage_static_pages?: permitted?(user, :edit, %StaticPage{}),
      can_manage_mod_notes?: permitted?(user, :index, ModNote),
      can_view_moderation_log?: permitted?(user, :index, ModerationLog),
      can_manage_bans?: permitted?(user, :create, UserBan),
      can_view_approvals?: permitted?(user, :approve, Image),
      can_view_duplicate_reports?: permitted?(user, :index, DuplicateReport),
      can_view_reports?: permitted?(user, :index, Report),
      can_view_artist_links?: permitted?(user, :index, ArtistLink),
      can_view_dnp_entries?: permitted?(user, :index, DnpEntry),
      show_admin_menu?: false,
      pending_approval_count: Images.count_pending_approvals(actor),
      duplicate_report_count: DuplicateReports.count_duplicate_reports(actor),
      report_count: Reports.count_open_reports(actor),
      artist_link_count: ArtistLinks.count_artist_links(actor),
      dnp_entry_count: DnpEntries.count_dnp_entries(actor)
    }

    show_admin_menu? =
      Enum.any?(@management_destination_keys, &Map.fetch!(navigation, &1))

    %{navigation | show_admin_menu?: show_admin_menu?}
  end
end
