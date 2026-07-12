defmodule PhilomenaWeb.DuplicateReport.ClaimController do
  use PhilomenaWeb, :controller

  alias Philomena.DuplicateReports

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"duplicate_report_id" => id}) do
    with {:ok, _report} <- DuplicateReports.claim_duplicate_report(conn.assigns.current_user, id) do
      conn
      |> put_flash(:info, "Successfully claimed report.")
      |> redirect(to: ~p"/duplicate_reports")
    end
  end

  def delete(conn, %{"duplicate_report_id" => id}) do
    with {:ok, _report} <-
           DuplicateReports.unclaim_duplicate_report(conn.assigns.current_user, id) do
      conn
      |> put_flash(:info, "Successfully released report.")
      |> redirect(to: ~p"/duplicate_reports")
    end
  end
end
