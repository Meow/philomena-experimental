defmodule PhilomenaWeb.CommissionController do
  use PhilomenaWeb, :controller

  alias Philomena.Commissions

  plug PhilomenaWeb.MapParameterPlug, [param: "commission"] when action in [:index]

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    commission_params = Map.get(params, "commission", %{})

    with {:ok, directory} <-
           Commissions.load_directory(
             conn.assigns.actor,
             commission_params,
             conn.assigns.scrivener
           ) do
      conn
      |> assign(:current_user, directory.current_user)
      |> render("index.html",
        title: "Commissions",
        commissions: directory.commissions,
        changeset: directory.changeset,
        layout_class: "layout--wide"
      )
    end
  end
end
