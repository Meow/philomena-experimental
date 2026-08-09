defmodule PhilomenaWeb.Api.Json.Forum.Topic.PostController do
  use PhilomenaWeb, :controller

  alias Philomena.Posts
  import PhilomenaWeb.Api.Json.NotFound

  def index(conn, %{"forum_id" => forum_id, "topic_id" => topic_id}) do
    case Posts.list_topic_posts(
           conn.assigns.actor,
           forum_id,
           topic_id,
           conn.assigns.pagination
         ) do
      {:ok, listing} ->
        render(conn, "index.json",
          posts: listing.posts.entries,
          total: listing.posts.total_entries
        )

      {:error, reason} when reason in [:not_found, :unauthorized] ->
        not_found(conn)
    end
  end

  def show(conn, %{"forum_id" => forum_id, "topic_id" => topic_id, "id" => id}) do
    case Posts.load_topic_post(conn.assigns.actor, forum_id, topic_id, id) do
      {:ok, post} -> render(conn, "show.json", post: post)
      {:error, reason} when reason in [:not_found, :unauthorized] -> not_found(conn)
    end
  end
end
