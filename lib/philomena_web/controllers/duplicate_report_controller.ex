defmodule PhilomenaWeb.DuplicateReportController do
  use PhilomenaWeb, :controller

  alias Philomena.DuplicateReports

  plug PhilomenaWeb.UserAttributionPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    duplicate_reports = DuplicateReports.list_duplicate_reports(params, conn.assigns.scrivener)

    render(conn, "index.html",
      title: "Duplicate Reports",
      duplicate_reports: duplicate_reports,
      layout_class: "layout--wide"
    )
  end

  def show(conn, %{"id" => id}) do
    with {:ok, duplicate_report} <- DuplicateReports.show_duplicate_report(id) do
      render(conn, "show.html",
        title: "Showing Duplicate Report",
        duplicate_report: duplicate_report,
        layout_class: "layout--wide"
      )
    end
  end

  def create(conn, params) do
    case DuplicateReports.create_duplicate_report(conn.assigns.actor, params) do
      {:ok, duplicate_report} ->
        conn
        |> put_flash(:info, "Duplicate report created successfully.")
        |> redirect(to: ~p"/images/#{duplicate_report.image_id}")

      {:error, :report_failed, source} ->
        conn
        |> put_flash(:error, "Failed to submit duplicate report")
        |> redirect(to: ~p"/images/#{source}")

      error ->
        error
    end
  end
end
