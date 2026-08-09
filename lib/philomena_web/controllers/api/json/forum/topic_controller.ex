defmodule PhilomenaWeb.Api.Json.Forum.TopicController do
  use PhilomenaWeb, :controller

  alias Philomena.Topics
  import PhilomenaWeb.Api.Json.NotFound

  def index(conn, %{"forum_id" => forum_id}) do
    case Topics.list_topics(conn.assigns.actor, forum_id, conn.assigns.pagination) do
      {:ok, {_forum, topics}} ->
        render(conn, "index.json", topics: topics, total: topics.total_entries)

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        not_found(conn)
    end
  end

  def show(conn, %{"forum_id" => forum_id, "id" => id}) do
    case Topics.load_topic(conn.assigns.actor, forum_id, id) do
      {:ok, result} -> render(conn, "show.json", topic: result.topic)
      {:error, reason} when reason in [:not_found, :unauthorized] -> not_found(conn)
    end
  end
end
