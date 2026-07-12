defmodule PhilomenaWeb.Admin.User.ApiKeyController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def delete(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_reset_api_key(conn.assigns.current_user, slug) do
      conn
      |> put_flash(:info, "API token successfully reset.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end
end
