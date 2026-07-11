defmodule PhilomenaWeb.Image.Comment.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportView
  alias Philomena.Comments
  alias Philomena.Reports

  plug PhilomenaWeb.UserAttributionPlug
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
        reportable: comment,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"image_id" => image_id, "comment_id" => comment_id} = params) do
    with {:ok, comment} <-
           Comments.load_comment_for_report_creation(conn.assigns.actor, image_id, comment_id) do
      action = ~p"/images/#{comment.image}/comments/#{comment}/reports"

      case Reports.create_report(conn.assigns.actor, "Comment", comment.id, params["report"]) do
        {:ok, _report} ->
          conn
          |> put_flash(
            :info,
            "Your report has been received and will be checked by staff shortly."
          )
          |> redirect(to: report_redirect_path(conn.assigns.current_user))

        {:error, :too_many_reports} ->
          conn
          |> put_flash(
            :error,
            "You may not have more than #{Reports.max_open_reports()} open reports at a time. " <>
              "Did you read the reporting tips?"
          )
          |> redirect(to: "/")

        {:error, %Ecto.Changeset{} = changeset} ->
          conn
          |> put_view(ReportView)
          |> render("new.html", reportable: comment, changeset: changeset, action: action)
      end
    end
  end

  defp report_redirect_path(nil), do: "/"
  defp report_redirect_path(_user), do: ~p"/reports"
end
