defmodule PhilomenaWeb.Profile.ScratchpadController do
  use PhilomenaWeb, :controller

  alias Philomena.Users
  alias Philomena.Users.UserForm

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, %{"profile_id" => slug}) do
    with {:ok, %UserForm{user: user, changeset: changeset}} <-
           Users.load_profile_for_scratchpad_edit(conn.assigns.actor, slug) do
      render(conn, "edit.html",
        title: "Editing Moderation Scratchpad",
        changeset: changeset,
        user: user
      )
    end
  end

  def update(conn, %{"profile_id" => slug, "user" => user_params}) do
    case Users.update_scratchpad(conn.assigns.actor, slug, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Moderation scratchpad successfully updated.")
        |> redirect(to: ~p"/profiles/#{user}")

      {:error, %UserForm{user: user, changeset: changeset}} ->
        render(conn, "edit.html", changeset: changeset, user: user)

      {:error, _} = error ->
        error
    end
  end
end
