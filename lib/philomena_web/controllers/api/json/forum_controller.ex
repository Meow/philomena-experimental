defmodule PhilomenaWeb.Api.Json.ForumController do
  use PhilomenaWeb, :controller

  alias Philomena.Forums
  import PhilomenaWeb.Api.Json.NotFound

  def index(conn, _params) do
    forum_index = Forums.load_forum_index(conn.assigns.actor, conn.assigns.scrivener)

    render(conn, forums: forum_index.forums, total: forum_index.forums.total_entries)
  end

  def show(conn, %{"id" => id}) do
    case Forums.load_forum(conn.assigns.actor, id) do
      {:ok, forum} -> render(conn, forum: forum)
      {:error, reason} when reason in [:not_found, :unauthorized] -> not_found(conn)
    end
  end
end
