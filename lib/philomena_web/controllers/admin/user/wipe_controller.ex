defmodule PhilomenaWeb.Admin.User.WipeController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_wipe_user(conn.assigns.actor, slug) do
      conn
      |> put_flash(
        :info,
        "PII wipe queued, please verify and then deactivate the account as necessary."
      )
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end
end
