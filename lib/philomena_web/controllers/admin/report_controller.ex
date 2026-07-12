defmodule PhilomenaWeb.Admin.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Reports

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    with {:ok, page} <-
           Reports.load_report_index(conn.assigns.current_user, params, conn.assigns.pagination) do
      render(conn, "index.html",
        title: "Admin - Reports",
        layout_class: "layout--wide",
        reports: page.reports,
        my_reports: page.my_reports,
        system_reports: page.system_reports
      )
    end
  end

  def show(conn, params) do
    with {:ok, report} <- Reports.load_report(conn.assigns.current_user, params["id"]) do
      body = MarkdownRenderer.render_one(%{body: report.reason}, conn)

      render(conn, "show.html",
        title: "Showing Report",
        report: report,
        body: body,
        mod_notes: mod_notes(conn, report)
      )
    end
  end

  defp mod_notes(conn, report) do
    renderer = &MarkdownRenderer.render_collection(&1, conn)
    Reports.mod_notes(conn.assigns.current_user, report, renderer)
  end
end
