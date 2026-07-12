defmodule PhilomenaWeb.CommissionController do
  use PhilomenaWeb, :controller

  alias Philomena.Commissions

  plug PhilomenaWeb.MapParameterPlug, [param: "commission"] when action in [:index]
  plug :preload_commission

  def index(conn, params) do
    commission_params = Map.get(params, "commission", %{})

    {commissions, changeset} =
      Commissions.search_directory(commission_params, conn.assigns.scrivener)

    render(conn, "index.html",
      title: "Commissions",
      commissions: commissions,
      changeset: changeset,
      layout_class: "layout--wide"
    )
  end

  defp preload_commission(conn, _opts) do
    assign(conn, :current_user, Commissions.preload_commission(conn.assigns.current_user))
  end
end
