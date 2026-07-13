defmodule PhilomenaWeb.Api.Json.ForumController do
  use PhilomenaWeb, :controller

  alias Philomena.Forums
  import PhilomenaWeb.Api.Json.NotFound

  def index(conn, _params) do
    forums = Forums.api_list_forums(conn.assigns.scrivener)

    render(conn, forums: forums, total: forums.total_entries)
  end

  def show(conn, %{"id" => id}) do
    case Forums.api_show_forum(id) do
      {:ok, forum} -> render(conn, forum: forum)
      {:error, :not_found} -> not_found(conn)
    end
  end
end
