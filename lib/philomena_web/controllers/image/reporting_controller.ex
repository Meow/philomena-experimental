defmodule PhilomenaWeb.Image.ReportingController do
  use PhilomenaWeb, :controller

  alias Philomena.DuplicateReports.DuplicateReport
  alias Philomena.DuplicateReports

  action_fallback PhilomenaWeb.FallbackController

  def show(conn, params) do
    with {:ok, {image, dupe_reports}} <-
           DuplicateReports.image_duplicate_reports(conn.assigns.actor, params["image_id"]) do
      changeset = DuplicateReports.change_duplicate_report(%DuplicateReport{})

      render(conn, "show.html",
        layout: false,
        image: image,
        dupe_reports: dupe_reports,
        changeset: changeset
      )
    end
  end
end
