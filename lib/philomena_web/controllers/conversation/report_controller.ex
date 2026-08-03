defmodule PhilomenaWeb.Conversation.ReportController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ReportController
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
        subject: conversation,
        changeset: changeset,
        action: action
      )
    end
  end

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    with {:ok, conversation} <-
           Reports.load_conversation_for_report_creation(conn.assigns.actor, conversation_id) do
      action = ~p"/conversations/#{conversation}/reports"

      ReportController.create(
        conn,
        action,
        conversation,
        [conversation_id: conversation.id],
        params
      )
    end
  end
end
