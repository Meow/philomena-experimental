defmodule PhilomenaWeb.DuplicateReport.AcceptReverseController do
  use PhilomenaWeb, :controller

  alias Philomena.DuplicateReports

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"duplicate_report_id" => id}) do
    case DuplicateReports.accept_reverse_duplicate_report(conn.assigns.actor, id) do
      {:ok, _results} ->
        conn
        |> put_flash(:info, "Successfully accepted report in reverse.")
        |> redirect(to: ~p"/duplicate_reports")

      {:error, :report_failed} ->
        conn
        |> put_flash(:error, "Failed to accept report! Maybe someone else already accepted it.")
        |> redirect(to: ~p"/duplicate_reports")

      error ->
        error
    end
  end
end
