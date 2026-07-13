defmodule PhilomenaWeb.Api.Json.Forum.Topic.PostController do
  use PhilomenaWeb, :controller

  alias Philomena.Posts
  import PhilomenaWeb.Api.Json.NotFound

  def index(conn, %{"forum_id" => forum_id, "topic_id" => topic_id}) do
    case Posts.list_public_topic_posts(forum_id, topic_id, conn.assigns.pagination) do
      {:ok, {topic, posts}} ->
        render(conn, "index.json", posts: posts, total: topic.post_count)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def show(conn, %{"forum_id" => forum_id, "topic_id" => topic_id, "id" => id}) do
    case Posts.load_public_topic_post(forum_id, topic_id, id) do
      {:ok, post} -> render(conn, "show.json", post: post)
      {:error, :not_found} -> not_found(conn)
    end
  end
end
