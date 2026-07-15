defmodule PhilomenaWeb.Admin.Report.CloseController do
  use PhilomenaWeb, :controller

  alias Philomena.Reports

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"report_id" => report_id}) do
    with {:ok, _report} <- Reports.close_report(conn.assigns.actor, report_id) do
      conn
      |> put_flash(:info, "Successfully closed report")
      |> redirect(to: ~p"/admin/reports")
    end
  end
end
