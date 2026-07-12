defmodule PhilomenaWeb.Profile.Commission.ItemController do
  use PhilomenaWeb, :controller

  alias Philomena.Commissions

  plug PhilomenaWeb.UserAttributionPlug

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"profile_id" => slug}) do
    with {:ok, {user, commission, changeset}} <-
           Commissions.load_item_for_new(conn.assigns.actor, slug) do
      render(conn, "new.html",
        title: "New Commission Item",
        user: user,
        commission: commission,
        changeset: changeset
      )
    end
  end

  def create(conn, %{"profile_id" => slug, "item" => item_params}) do
    case Commissions.create_item(conn.assigns.actor, slug, item_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Item successfully created.")
        |> redirect(to: ~p"/profiles/#{user}/commission")

      {:error, {user, commission, changeset}} ->
        render(conn, "new.html", user: user, commission: commission, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  def edit(conn, %{"profile_id" => slug, "id" => id}) do
    with {:ok, {user, commission, item, changeset}} <-
           Commissions.load_item_for_edit(conn.assigns.actor, slug, id) do
      render(conn, "edit.html",
        title: "Editing Commission Item",
        user: user,
        commission: commission,
        item: item,
        changeset: changeset
      )
    end
  end

  def update(conn, %{"profile_id" => slug, "id" => id, "item" => item_params}) do
    case Commissions.update_item(conn.assigns.actor, slug, id, item_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Item successfully updated.")
        |> redirect(to: ~p"/profiles/#{user}/commission")

      {:error, {user, commission, item, changeset}} ->
        render(conn, "edit.html",
          user: user,
          commission: commission,
          item: item,
          changeset: changeset
        )

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, %{"profile_id" => slug, "id" => id}) do
    with {:ok, user} <- Commissions.delete_item(conn.assigns.actor, slug, id) do
      conn
      |> put_flash(:info, "Item deleted successfully.")
      |> redirect(to: ~p"/profiles/#{user}/commission")
    end
  end
end
