defmodule PhilomenaWeb.Profile.Commission.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportController
  alias PhilomenaWeb.ReportView
  alias Philomena.Reports

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"profile_id" => slug}) do
    with {:ok, {user, commission, changeset}} <-
           Reports.load_commission_for_report(conn.assigns.actor, slug) do
      action = ~p"/profiles/#{user}/commission/reports"

      conn
      |> put_view(ReportView)
      |> render("new.html",
        title: "Reporting Commission",
        reportable: commission,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"profile_id" => slug} = params) do
    with {:ok, {user, commission}} <-
           Reports.load_commission_for_report_creation(conn.assigns.actor, slug) do
      action = ~p"/profiles/#{user}/commission/reports"

      ReportController.create(
        conn,
        action,
        commission,
        [commission_id: commission.id],
        params
      )
    end
  end
end
