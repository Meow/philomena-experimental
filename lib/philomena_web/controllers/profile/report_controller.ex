defmodule PhilomenaWeb.Profile.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportController
  alias PhilomenaWeb.ReportView
  alias Philomena.Reports

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"profile_id" => slug}) do
    with {:ok, {user, changeset}} <- Reports.load_user_for_report(conn.assigns.actor, slug) do
      action = ~p"/profiles/#{user}/reports"

      conn
      |> put_view(ReportView)
      |> render("new.html",
        title: "Reporting User",
        subject: user,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"profile_id" => slug} = params) do
    with {:ok, user} <- Reports.load_user_for_report_creation(conn.assigns.actor, slug) do
      action = ~p"/profiles/#{user}/reports"

      ReportController.create(conn, action, user, [reported_user_id: user.id], params)
    end
  end
end
