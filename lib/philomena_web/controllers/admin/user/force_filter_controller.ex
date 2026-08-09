defmodule PhilomenaWeb.Admin.User.ForceFilterController do
  use PhilomenaWeb, :controller

  alias Philomena.Users
  alias Philomena.Users.UserForm

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"user_id" => slug}) do
    with {:ok, %UserForm{user: user, changeset: changeset}} <-
           Users.load_user_for_force_filter(conn.assigns.actor, slug) do
      render(conn, "new.html",
        title: "Forcing filter for user",
        user: user,
        changeset: changeset
      )
    end
  end

  def create(conn, %{"user_id" => slug, "user" => user_params}) do
    case Users.admin_force_filter(conn.assigns.actor, slug, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Filter was forced.")
        |> redirect(to: ~p"/profiles/#{user}")

      {:error, %UserForm{user: user, changeset: changeset}} ->
        render(conn, "new.html",
          title: "Forcing filter for user",
          user: user,
          changeset: changeset
        )

      {:error, _reason} = error ->
        error
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
