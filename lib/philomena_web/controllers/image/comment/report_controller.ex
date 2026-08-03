defmodule PhilomenaWeb.Image.Comment.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportView
  alias Philomena.Comments
  alias Philomena.Reports

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"image_id" => image_id, "comment_id" => comment_id}) do
    with {:ok, {comment, changeset}} <-
           Comments.load_comment_for_report(conn.assigns.actor, image_id, comment_id) do
      action = ~p"/images/#{comment.image}/comments/#{comment}/reports"

      conn
      |> put_view(ReportView)
      |> render("new.html",
        title: "Reporting Comment",
        subject: comment,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"image_id" => image_id, "comment_id" => comment_id} = params) do
    with {:ok, comment} <-
           Comments.load_comment_for_report_creation(conn.assigns.actor, image_id, comment_id) do
      action = ~p"/images/#{comment.image}/comments/#{comment}/reports"

      ReportController.create(conn, action, comment, [comment_id: comment.id], params)
    end
  end
end
