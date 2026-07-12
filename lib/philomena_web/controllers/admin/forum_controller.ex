defmodule PhilomenaWeb.Admin.ForumController do
  use PhilomenaWeb, :controller

  alias Philomena.Forums

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, _params) do
    with :ok <- Forums.authorize_admin(conn.assigns.current_user) do
      render(conn, "index.html", title: "Admin - Forums")
    end
  end

  def new(conn, _params) do
    with {:ok, changeset} <- Forums.new_forum(conn.assigns.current_user) do
      render(conn, "new.html", title: "New Forum", changeset: changeset)
    end
  end

  def create(conn, %{"forum" => forum_params}) do
    case Forums.create_forum(conn.assigns.current_user, forum_params) do
      {:ok, _forum} ->
        conn
        |> put_flash(:info, "Forum created successfully.")
        |> redirect(to: ~p"/admin/forums")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)

      {:error, :unauthorized} = error ->
        error
    end
  end

  def edit(conn, params) do
    with {:ok, {forum, changeset}} <-
           Forums.load_forum_for_edit(conn.assigns.current_user, params["id"]) do
      render(conn, "edit.html", title: "Editing Forum", forum: forum, changeset: changeset)
    end
  end

  def update(conn, %{"id" => id, "forum" => forum_params}) do
    case Forums.update_forum(conn.assigns.current_user, id, forum_params) do
      {:ok, _forum} ->
        conn
        |> put_flash(:info, "Forum updated successfully.")
        |> redirect(to: ~p"/admin/forums")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", forum: changeset.data, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end
end
