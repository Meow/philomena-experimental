defmodule PhilomenaWeb.Topic.MoveController do
  use PhilomenaWeb, :controller

  alias Philomena.Topics

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    case Topics.move_topic(
           conn.assigns.current_user,
           params["forum_id"],
           params["topic_id"],
           params["topic"]
         ) do
      {:ok, {forum, topic}} ->
        conn
        |> put_flash(:info, "Topic successfully moved!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, forum, topic} ->
        conn
        |> put_flash(:error, "Unable to move the topic!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, _} = error ->
        error
    end
  end
end
