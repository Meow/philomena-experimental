defmodule PhilomenaWeb.AvatarController do
  use PhilomenaWeb, :controller

  alias Philomena.Users
  alias Philomena.Users.UserForm

  plug PhilomenaWeb.ScraperPlug,
       [params_name: "user", params_key: "avatar"] when action in [:update]

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, _params) do
    with {:ok, %UserForm{changeset: changeset}} <-
           Users.load_user_for_avatar_edit(conn.assigns.actor) do
      render(conn, "edit.html", title: "Editing Avatar", changeset: changeset)
    end
  end

  def update(conn, %{"user" => user_params}) do
    case Users.update_avatar(conn.assigns.actor, user_params) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Successfully updated avatar.")
        |> redirect(to: ~p"/avatar/edit")

      {:error, %UserForm{changeset: changeset}} ->
        render(conn, "edit.html", changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, _params) do
    with {:ok, _user} <- Users.remove_avatar(conn.assigns.actor) do
      conn
      |> put_flash(:info, "Successfully removed avatar.")
      |> redirect(to: ~p"/avatar/edit")
    end
  end
end
