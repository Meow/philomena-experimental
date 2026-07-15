defmodule PhilomenaWeb.Admin.User.ForceFilterController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.load_user_for_force_filter(conn.assigns.actor, slug) do
      render(conn, "new.html",
        title: "Forcing filter for user",
        user: user,
        changeset: Users.change_user(user)
      )
    end
  end

  def create(conn, %{"user_id" => slug, "user" => user_params}) do
    with {:ok, user} <- Users.admin_force_filter(conn.assigns.actor, slug, user_params) do
      conn
      |> put_flash(:info, "Filter was forced.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end

  def delete(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_unforce_filter(conn.assigns.actor, slug) do
      conn
      |> put_flash(:info, "Forced filter was removed.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end
end
