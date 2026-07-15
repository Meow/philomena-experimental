defmodule PhilomenaWeb.Conversation.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportView
  alias Philomena.Reports

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def new(conn, %{"conversation_id" => conversation_id}) do
    with {:ok, {conversation, changeset}} <-
           Reports.load_conversation_for_report(conn.assigns.actor, conversation_id) do
      action = ~p"/conversations/#{conversation}/reports"

      conn
      |> put_view(ReportView)
      |> render("new.html",
        title: "Reporting Conversation",
        reportable: conversation,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, conversation} <-
           Reports.load_conversation_for_report_creation(conn.assigns.actor, conversation_id) do
      action = ~p"/conversations/#{conversation}/reports"

      case Reports.create_report(
             conn.assigns.actor,
             "Conversation",
             conversation.id,
             params["report"]
           ) do
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
          |> render("new.html", reportable: conversation, changeset: changeset, action: action)
      end
    end
  end

  defp report_redirect_path(nil), do: "/"
  defp report_redirect_path(_user), do: ~p"/reports"
end
