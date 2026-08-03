defmodule PhilomenaWeb.Gallery.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportController
  alias PhilomenaWeb.ReportView
  alias Philomena.Reports

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"gallery_id" => gallery_id}) do
    with {:ok, {gallery, changeset}} <-
           Reports.load_gallery_for_report(conn.assigns.actor, gallery_id) do
      action = ~p"/galleries/#{gallery}/reports"

      conn
      |> put_view(ReportView)
      |> render("new.html",
        title: "Reporting Gallery",
        subject: gallery,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"gallery_id" => gallery_id} = params) do
    with {:ok, gallery} <-
           Reports.load_gallery_for_report_creation(conn.assigns.actor, gallery_id) do
      action = ~p"/galleries/#{gallery}/reports"

      ReportController.create(conn, action, gallery, [gallery_id: gallery.id], params)
    end
  end
end
