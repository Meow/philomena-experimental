defmodule PhilomenaWeb.Profile.CommissionController do
  use PhilomenaWeb, :controller

  alias Philomena.Commissions.Commission
  alias Philomena.Commissions
  alias PhilomenaWeb.MarkdownRenderer

  action_fallback PhilomenaWeb.FallbackController

  def show(conn, %{"profile_id" => slug}) do
    with {:ok, {user, commission}} <- Commissions.load_commission_for_show(slug) do
      items =
        commission.items
        |> Enum.sort(&(Decimal.compare(&1.base_price, &2.base_price) != :gt))

      item_descriptions =
        items
        |> Enum.map(&%{body: &1.description})
        |> MarkdownRenderer.render_collection(conn)

      item_add_ons =
        items
        |> Enum.map(&%{body: &1.add_ons})
        |> MarkdownRenderer.render_collection(conn)

      [information, contact, will_create, will_not_create] =
        MarkdownRenderer.render_collection(
          [
            %{body: commission.information || ""},
            %{body: commission.contact || ""},
            %{body: commission.will_create || ""},
            %{body: commission.will_not_create || ""}
          ],
          conn
        )

      rendered = %{
        information: information,
        contact: contact,
        will_create: will_create,
        will_not_create: will_not_create
      }

      items = Enum.zip([item_descriptions, item_add_ons, items])

      render(conn, "show.html",
        title: "Showing Commission",
        user: user,
        rendered: rendered,
        commission: commission,
        items: items,
        layout_class: "layout--wide"
      )
    end
  end

  def new(conn, %{"profile_id" => slug}) do
    case Commissions.load_commission_for_new(conn.assigns.actor, slug) do
      {:ok, user} ->
        render(conn, "new.html",
          title: "New Commission",
          user: user,
          changeset: Commissions.change_commission(%Commission{})
        )

      {:error, :no_verified_links} ->
        require_verified_link(conn)

      {:error, _} = error ->
        error
    end
  end

  def create(conn, %{"profile_id" => slug, "commission" => commission_params}) do
    case Commissions.create_commission(conn.assigns.actor, slug, commission_params) do
      {:ok, {user, _commission}} ->
        conn
        |> put_flash(:info, "Commission successfully created.")
        |> redirect(to: ~p"/profiles/#{user}/commission")

      {:error, {user, changeset}} ->
        render(conn, "new.html", user: user, changeset: changeset)

      {:error, :no_verified_links} ->
        require_verified_link(conn)

      {:error, _} = error ->
        error
    end
  end

  def edit(conn, %{"profile_id" => slug}) do
    case Commissions.load_commission_for_edit(conn.assigns.actor, slug) do
      {:ok, {user, _commission, changeset}} ->
        render(conn, "edit.html", title: "Editing Commission", user: user, changeset: changeset)

      {:error, :no_verified_links} ->
        require_verified_link(conn)

      {:error, _} = error ->
        error
    end
  end

  def update(conn, %{"profile_id" => slug, "commission" => commission_params}) do
    case Commissions.update_commission(conn.assigns.actor, slug, commission_params) do
      {:ok, {user, _commission}} ->
        conn
        |> put_flash(:info, "Commission successfully updated.")
        |> redirect(to: ~p"/profiles/#{user}/commission")

      {:error, {user, changeset}} ->
        render(conn, "edit.html", user: user, changeset: changeset)

      {:error, :no_verified_links} ->
        require_verified_link(conn)

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, %{"profile_id" => slug}) do
    case Commissions.delete_commission(conn.assigns.actor, slug) do
      {:ok, _commission} ->
        conn
        |> put_flash(:info, "Commission deleted successfully.")
        |> redirect(to: ~p"/commissions")

      {:error, :no_verified_links} ->
        require_verified_link(conn)

      {:error, _} = error ->
        error
    end
  end

  defp require_verified_link(conn) do
    conn
    |> put_flash(
      :error,
      "You must have a verified artist link to create a commission listing."
    )
    |> redirect(to: ~p"/commissions")
  end
end
