defmodule PhilomenaWeb.Image.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportController
  alias PhilomenaWeb.ReportView
  alias Philomena.Reports

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"image_id" => image_id}) do
    with {:ok, {image, changeset}} <- Reports.load_image_for_report(conn.assigns.actor, image_id) do
      action = ~p"/images/#{image}/reports"

      conn
      |> put_view(ReportView)
      |> render("new.html",
        title: "Reporting Image",
        subject: image,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"image_id" => image_id} = params) do
    with {:ok, image} <- Reports.load_image_for_report_creation(conn.assigns.actor, image_id) do
      action = ~p"/images/#{image}/reports"

      ReportController.create(conn, action, image, [image_id: image.id], params)
    end
  end
end
