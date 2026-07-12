defmodule PhilomenaWeb.ConversationController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.NotificationCountPlug
  alias Philomena.Conversations
  alias PhilomenaWeb.MarkdownRenderer

  plug PhilomenaWeb.UserAttributionPlug when action in [:new, :create]

  plug PhilomenaWeb.LimitPlug,
       [time: 60, error: "You may only create a conversation once every minute."]
       when action in [:create]

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    conversations =
      Conversations.list_conversations(conn.assigns.current_user, params, conn.assigns.scrivener)

    render(conn, "index.html", title: "Conversations", conversations: conversations)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, page} <-
           Conversations.load_conversation_page(
             conn.assigns.current_user,
             id,
             conn.assigns.scrivener
           ) do
      # The page load marked the conversation read; refresh the header
      # notification ticker afterwards so it reflects the cleared state.
      conn = NotificationCountPlug.call(conn)

      rendered = MarkdownRenderer.render_collection(page.messages.entries, conn)
      messages = %{page.messages | entries: Enum.zip(page.messages.entries, rendered)}

      render(conn, "show.html",
        title: "Showing Conversation",
        conversation: page.conversation,
        messages: messages,
        changeset: page.changeset
      )
    end
  end

  def new(conn, params) do
    with {:ok, changeset} <-
           Conversations.load_new_conversation(conn.assigns.actor, params["recipient"]) do
      render(conn, "new.html", title: "New Conversation", changeset: changeset)
    end
  end

  def create(conn, params) do
    case Conversations.create_conversation(conn.assigns.actor, params["conversation"]) do
      {:ok, conversation} ->
        conn
        |> put_flash(:info, "Conversation successfully created.")
        |> redirect(to: ~p"/conversations/#{conversation}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)

      {:error, _} = error ->
        error
    end
  end
end
