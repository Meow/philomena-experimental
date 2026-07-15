defmodule PhilomenaWeb.Conversation.MessageController do
  use PhilomenaWeb, :controller

  alias Philomena.Conversations

  action_fallback PhilomenaWeb.FallbackController

  @page_size 25

  def create(conn, %{"conversation_id" => conversation_id} = params) do
    case Conversations.create_message(conn.assigns.actor, conversation_id, params["message"]) do
      {:ok, {conversation, _message}} ->
        count = Conversations.count_messages(conversation)
        page = div(count + @page_size - 1, @page_size)

        conn
        |> put_flash(:info, "Message successfully sent.")
        |> redirect(to: ~p"/conversations/#{conversation}?#{[page: page]}")

      {:error, {:message_failed, conversation}} ->
        conn
        |> put_flash(:error, "There was an error posting your message")
        |> redirect(to: ~p"/conversations/#{conversation}")

      {:error, _} = error ->
        error
    end
  end
end
