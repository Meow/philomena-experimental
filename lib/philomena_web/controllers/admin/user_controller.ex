defmodule PhilomenaWeb.Admin.UserController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    with {:ok, users} <-
           Users.search_users(conn.assigns.actor, params, conn.assigns.pagination) do
      render(conn, "index.html",
        title: "Admin - Users",
        layout_class: "layout--medium",
        users: users
      )
    else
      {:error, :unauthorized} = error ->
        error

      {:error, msg} ->
        render(conn, "index.html",
          title: "Admin - Users",
          layout_class: "layout--medium",
          users: [],
          error: msg
        )
    end
  end

  def edit(conn, %{"id" => slug}) do
    with {:ok, user} <- Users.load_user_for_edit(conn.assigns.actor, slug) do
      render(conn, "edit.html",
        title: "Editing User",
        user: user,
        changeset: Users.change_user(user),
        roles: Users.list_roles()
      )
    end
  end

  def update(conn, %{"id" => slug, "user" => user_params}) do
    with {:ok, user} <- Users.update_user_details(conn.assigns.actor, slug, user_params) do
      conn
      |> put_flash(:info, "User successfully updated.")
      |> redirect(to: ~p"/profiles/#{user}")
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html",
          user: changeset.data,
          changeset: changeset,
          roles: Users.list_roles()
        )

      error ->
        error
    end
  end
end
