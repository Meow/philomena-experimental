defmodule PhilomenaWeb.Admin.DonationController do
  use PhilomenaWeb, :controller

  alias Philomena.Donations

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, _params) do
    with {:ok, donations} <-
           Donations.load_donations(conn.assigns.current_user, conn.assigns.scrivener) do
      render(conn, "index.html", title: "Admin - Donations", donations: donations)
    end
  end

  def create(conn, %{"donation" => donation_params}) do
    case Donations.create_donation(conn.assigns.current_user, donation_params) do
      {:ok, _donation} ->
        conn
        |> put_flash(:info, "Donation successfully created.")
        |> redirect(to: ~p"/admin/donations")

      {:error, :unauthorized} = error ->
        error

      _error ->
        conn
        |> put_flash(:error, "Error creating donation!")
        |> redirect(to: ~p"/admin/donations")
    end
  end
end
