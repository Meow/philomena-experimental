defmodule PhilomenaWeb.Admin.User.VerificationController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_verify_user(conn.assigns.actor, slug) do
      conn
      |> put_flash(:info, "User verification granted.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end

  def delete(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_unverify_user(conn.assigns.actor, slug) do
      conn
      |> put_flash(:info, "User verification revoked.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end
end
