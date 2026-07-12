defmodule PhilomenaWeb.Admin.User.UnlockController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_unlock_user(conn.assigns.current_user, slug) do
      conn
      |> put_flash(:info, "User was unlocked.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end
end
