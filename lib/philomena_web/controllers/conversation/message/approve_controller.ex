defmodule PhilomenaWeb.Conversation.Message.ApproveController do
  use PhilomenaWeb, :controller

  alias Philomena.Conversations

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"message_id" => message_id}) do
    with {:ok, _message} <- Conversations.approve_message(conn.assigns.actor, message_id) do
      conn
      |> put_flash(:info, "Conversation message approved.")
      |> redirect(to: "/")
    end
  end
end
