defmodule PhilomenaWeb.Profile.IpHistoryController do
  use PhilomenaWeb, :controller

  alias Philomena.Profiles

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, %{"profile_id" => slug}) do
    with {:ok, history} <- Profiles.load_ip_history(conn.assigns.current_user, slug) do
      render(conn, "index.html",
        title: "IP History for `#{history.user.name}'",
        user: history.user,
        user_ips: history.user_ips,
        other_users: history.other_users
      )
    end
  end
end
