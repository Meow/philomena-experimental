defmodule PhilomenaWeb.IpProfileController do
  use PhilomenaWeb, :controller

  alias Philomena.UserIps

  action_fallback PhilomenaWeb.FallbackController

  def show(conn, %{"id" => ip}) do
    with {:ok, profile} <- UserIps.load_ip_profile(conn.assigns.current_user, ip) do
      render(conn, "show.html",
        title: "#{profile.ip}'s IP profile",
        ip: profile.ip,
        user_ips: profile.user_ips,
        subnet_bans: profile.subnet_bans
      )
    end
  end
end
