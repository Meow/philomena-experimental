defmodule PhilomenaWeb.Admin.User.ActivationController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_reactivate_user(conn.assigns.actor, slug) do
      conn
      |> put_flash(:info, "User was reactivated.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end

  def delete(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_deactivate_user(conn.assigns.actor, slug) do
      conn
      |> put_flash(:info, "User was deactivated.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end
end
