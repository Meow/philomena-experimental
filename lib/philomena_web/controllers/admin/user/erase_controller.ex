defmodule PhilomenaWeb.Admin.User.EraseController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"user_id" => slug}) do
    case Users.load_user_for_erase(conn.assigns.actor, slug) do
      {:ok, user} ->
        render(conn, "new.html", title: "Erase user", user: user)

      error ->
        render_erase_error(conn, error)
    end
  end

  def create(conn, %{"user_id" => slug}) do
    case Users.admin_erase_user(conn.assigns.actor, slug) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "User erase started")
        |> redirect(to: ~p"/profiles/#{user}")

      error ->
        render_erase_error(conn, error)
    end
  end

  defp render_erase_error(conn, error) do
    case error do
      {:error, :not_erasable} ->
        conn
        |> put_flash(:error, "Couldn't find that username. Was it already erased?")
        |> redirect(to: ~p"/admin/users")

      {:error, {:privileged, user}} ->
        conn
        |> put_flash(:error, "Cannot erase a privileged user")
        |> redirect(to: ~p"/profiles/#{user}")

      {:error, {:verified, user}} ->
        conn
        |> put_flash(:error, "Cannot erase a verified user")
        |> redirect(to: ~p"/profiles/#{user}")

      {:error, :unauthorized} = err ->
        err
    end
  end
end
