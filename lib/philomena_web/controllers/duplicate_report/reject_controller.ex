defmodule PhilomenaWeb.DuplicateReport.RejectController do
  use PhilomenaWeb, :controller

  alias Philomena.DuplicateReports

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"duplicate_report_id" => id}) do
    with {:ok, _report} <- DuplicateReports.reject_duplicate_report(conn.assigns.actor, id) do
      conn
      |> put_flash(:info, "Successfully rejected report.")
      |> redirect(to: ~p"/duplicate_reports")
    end
  end
end
