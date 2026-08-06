defmodule PhilomenaWeb.Profile.Commission.ItemController do
  use PhilomenaWeb, :controller

  alias Philomena.Commissions
  alias Philomena.Commissions.ItemForm

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"profile_id" => slug}) do
    with {:ok, %ItemForm{} = form} <- Commissions.new_item(conn.assigns.actor, slug) do
      render(conn, "new.html",
        title: "New Commission Item",
        user: form.user,
        commission: form.commission,
        changeset: form.changeset
      )
    end
  end

  def create(conn, %{"profile_id" => slug, "item" => item_params}) do
    case Commissions.create_item(conn.assigns.actor, slug, item_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Item successfully created.")
        |> redirect(to: ~p"/profiles/#{user}/commission")

      {:error, %ItemForm{} = form} ->
        render(conn, "new.html",
          user: form.user,
          commission: form.commission,
          changeset: form.changeset
        )

      {:error, _} = error ->
        error
    end
  end

  def edit(conn, %{"profile_id" => slug, "id" => id}) do
    with {:ok, %ItemForm{} = form} <-
           Commissions.load_item_for_edit(conn.assigns.actor, slug, id) do
      render(conn, "edit.html",
        title: "Editing Commission Item",
        user: form.user,
        commission: form.commission,
        item: form.item,
        changeset: form.changeset
      )
    end
  end

  def update(conn, %{"profile_id" => slug, "id" => id, "item" => item_params}) do
    case Commissions.update_item(conn.assigns.actor, slug, id, item_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Item successfully updated.")
        |> redirect(to: ~p"/profiles/#{user}/commission")

      {:error, %ItemForm{} = form} ->
        render(conn, "edit.html",
          user: form.user,
          commission: form.commission,
          item: form.item,
          changeset: form.changeset
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
