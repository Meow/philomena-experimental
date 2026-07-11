defmodule PhilomenaWeb.Topic.Post.ApproveController do
  use PhilomenaWeb, :controller

  alias Philomena.Posts.Post
  alias Philomena.Posts

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"post_id" => post_id}) do
    case Posts.approve_post(conn.assigns.current_user, post_id) do
      {:ok, post} ->
        conn
        |> put_flash(:info, "Post successfully approved.")
        |> redirect(to: post_anchor(post))

      {:error, %Post{} = post} ->
        conn
        |> put_flash(:error, "Unable to approve post!")
        |> redirect(to: post_anchor(post))

      error ->
        error
    end
  end

  defp post_anchor(post) do
    ~p"/forums/#{post.topic.forum}/topics/#{post.topic}?#{[post_id: post.id]}" <>
      "#post_#{post.id}"
  end
end
