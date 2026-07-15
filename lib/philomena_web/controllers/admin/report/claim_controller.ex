defmodule PhilomenaWeb.Admin.Report.ClaimController do
  use PhilomenaWeb, :controller

  alias Philomena.Reports

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"report_id" => report_id}) do
    case Reports.claim_report(conn.assigns.actor, report_id) do
      {:ok, _report} ->
        conn
        |> put_flash(:info, "Successfully marked report as in progress")
        |> redirect(to: ~p"/admin/reports")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_flash(:error, "Couldn't claim that report!")
        |> redirect(to: ~p"/admin/reports/#{changeset.data}")

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, %{"report_id" => report_id}) do
    with {:ok, report} <- Reports.unclaim_report(conn.assigns.actor, report_id) do
      conn
      |> put_flash(:info, "Successfully released report.")
      |> redirect(to: ~p"/admin/reports/#{report}")
    end
  end
end
