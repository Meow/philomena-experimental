defmodule PhilomenaWeb.Api.Json.Forum.TopicController do
  use PhilomenaWeb, :controller

  alias Philomena.Topics
  import PhilomenaWeb.Api.Json.NotFound

  def index(conn, %{"forum_id" => forum_id}) do
    topics = Topics.api_list_topics(forum_id, conn.assigns.scrivener)

    render(conn, "index.json", topics: topics, total: topics.total_entries)
  end

  def show(conn, %{"forum_id" => forum_id, "id" => id}) do
    case Topics.api_show_topic(forum_id, id) do
      {:ok, topic} -> render(conn, "show.json", topic: topic)
      {:error, :not_found} -> not_found(conn)
    end
  end
end
