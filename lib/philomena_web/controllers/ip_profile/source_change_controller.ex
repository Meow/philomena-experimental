defmodule PhilomenaWeb.IpProfile.SourceChangeController do
  use PhilomenaWeb, :controller

  alias Philomena.SourceChanges
  alias Philomena.SourceChanges.SourceChangePage

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, %{"ip_profile_id" => ip} = params) do
    with {:ok, %SourceChangePage{target: ip, range: range, source_changes: source_changes}} <-
           SourceChanges.ip_source_changes(
             conn.assigns.actor,
             ip,
             params,
             conn.assigns.scrivener
           ) do
      render(conn, "index.html",
        title: "Source Changes for IP `#{ip}'",
        ip: range,
        source_changes: source_changes
      )
    end
  end
end
