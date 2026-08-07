defmodule PhilomenaWeb.Conversation.Message.ApproveController do
  use PhilomenaWeb, :controller

  alias Philomena.Conversations

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"conversation_id" => conversation_id, "message_id" => message_id}) do
    with {:ok, _message} <-
           Conversations.approve_message(conn.assigns.actor, conversation_id, message_id) do
      conn
      |> put_flash(:info, "Conversation message approved.")
      |> redirect(to: "/")
    end
  end
end
