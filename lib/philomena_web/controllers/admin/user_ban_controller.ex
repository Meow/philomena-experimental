defmodule PhilomenaWeb.Admin.UserBanController do
  use PhilomenaWeb, :controller

  alias Philomena.Bans

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    with {:ok, user_bans} <-
           Bans.admin_user_bans(conn.assigns.actor, params, conn.assigns.scrivener) do
      render(conn, "index.html",
        title: "Admin - User Bans",
        layout_class: "layout--wide",
        user_bans: user_bans
      )
    end
  end

  def new(conn, params) do
    case Bans.new_user_ban(conn.assigns.actor, params["user_id"]) do
      {:ok, {target_user, changeset}} ->
        render_new(conn, target_user, changeset)

      {:error, :no_target} ->
        no_target_user(conn)

      {:error, :unauthorized} = error ->
        error
    end
  end

  def create(conn, %{"user" => user_ban_params}) do
    case Bans.create_user_ban(conn.assigns.actor, user_ban_params) do
      {:ok, _user_ban} ->
        conn
        |> put_flash(:info, "User was successfully banned.")
        |> redirect(to: ~p"/admin/user_bans")

      {:error, %Ecto.Changeset{} = changeset} ->
        # `new.html` names the user being banned; the form posts their id back
        # in a hidden field.
        case Bans.target_user(user_ban_params["user_id"]) do
          nil -> no_target_user(conn)
          target_user -> render_new(conn, target_user, changeset)
        end

      {:error, :unauthorized} = error ->
        error
    end
  end

  def edit(conn, params) do
    with {:ok, {user_ban, changeset}} <-
           Bans.load_user_ban_for_edit(conn.assigns.actor, params["id"]) do
      render(conn, "edit.html", title: "Editing User Ban", user: user_ban, changeset: changeset)
    end
  end

  def update(conn, %{"id" => id, "user" => user_ban_params}) do
    case Bans.update_user_ban(conn.assigns.actor, id, user_ban_params) do
      {:ok, _user_ban} ->
        conn
        |> put_flash(:info, "User ban successfully updated.")
        |> redirect(to: ~p"/admin/user_bans")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", user: changeset.data, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, params) do
    with {:ok, _user_ban} <- Bans.delete_user_ban(conn.assigns.actor, params["id"]) do
      conn
      |> put_flash(:info, "User ban successfully deleted.")
      |> redirect(to: ~p"/admin/user_bans")
    end
  end

  defp render_new(conn, target_user, changeset) do
    render(conn, "new.html",
      title: "New User Ban",
      target_user: target_user,
      changeset: changeset
    )
  end

  defp no_target_user(conn) do
    conn
    |> put_flash(:error, "Must create ban on user.")
    |> redirect(to: ~p"/admin/user_bans")
  end
end
