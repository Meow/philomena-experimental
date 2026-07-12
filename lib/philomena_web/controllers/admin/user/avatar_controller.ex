defmodule PhilomenaWeb.Admin.User.AvatarController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def delete(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_remove_avatar(conn.assigns.current_user, slug) do
      conn
      |> put_flash(:info, "Successfully removed avatar.")
      |> redirect(to: ~p"/admin/users/#{user}/edit")
    end
  end
end
