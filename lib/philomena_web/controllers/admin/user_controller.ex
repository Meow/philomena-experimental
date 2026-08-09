defmodule PhilomenaWeb.Admin.UserController do
  use PhilomenaWeb, :controller

  alias Philomena.Users
  alias Philomena.Users.AdminUserForm

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
    with {:ok, %AdminUserForm{} = form} <-
           Users.load_user_for_edit(conn.assigns.actor, slug) do
      render(conn, "edit.html",
        title: "Editing User",
        user: form.user,
        changeset: form.changeset,
        roles: form.roles
      )
    end
  end

  def update(conn, %{"id" => slug, "user" => user_params}) do
    with {:ok, user} <- Users.update_user_details(conn.assigns.actor, slug, user_params) do
      conn
      |> put_flash(:info, "User successfully updated.")
      |> redirect(to: ~p"/profiles/#{user}")
    else
      {:error, %AdminUserForm{} = form} ->
        render(conn, "edit.html",
          user: form.user,
          changeset: form.changeset,
          roles: form.roles
        )

      error ->
        error
    end
  end
end
