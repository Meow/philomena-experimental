defmodule PhilomenaWeb.Profile.FpHistoryController do
  use PhilomenaWeb, :controller

  alias Philomena.Profiles

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, %{"profile_id" => slug}) do
    with {:ok, history} <- Profiles.load_fp_history(conn.assigns.actor, slug) do
      render(conn, "index.html",
        title: "FP History for `#{history.user.name}'",
        user: history.user,
        user_fps: history.user_fps,
        other_users: history.other_users
      )
    end
  end
end
