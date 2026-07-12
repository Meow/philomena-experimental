defmodule PhilomenaWeb.Profile.DescriptionController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  plug PhilomenaWeb.UserAttributionPlug

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, %{"profile_id" => slug}) do
    with {:ok, user} <- Users.load_profile_for_description_edit(conn.assigns.actor, slug) do
      render(conn, "edit.html",
        title: "Editing Profile Description",
        changeset: Users.change_user(user),
        user: user
      )
    end
  end

  def update(conn, %{"profile_id" => slug, "user" => user_params}) do
    case Users.update_description(conn.assigns.actor, slug, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Description successfully updated.")
        |> redirect(to: ~p"/profiles/#{user}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", changeset: changeset, user: changeset.data)

      {:error, _} = error ->
        error
    end
  end
end
