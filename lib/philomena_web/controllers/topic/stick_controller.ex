defmodule PhilomenaWeb.Topic.StickController do
  use PhilomenaWeb, :controller

  alias Philomena.Topics

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    case Topics.stick_topic(
           conn.assigns.current_user,
           params["forum_id"],
           params["topic_id"]
         ) do
      {:ok, {forum, topic}} ->
        conn
        |> put_flash(:info, "Topic successfully stickied!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, forum, topic} ->
        conn
        |> put_flash(:error, "Unable to stick the topic!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, params) do
    case Topics.unstick_topic(
           conn.assigns.current_user,
           params["forum_id"],
           params["topic_id"]
         ) do
      {:ok, {forum, topic}} ->
        conn
        |> put_flash(:info, "Topic successfully unstickied!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, forum, topic} ->
        conn
        |> put_flash(:error, "Unable to unstick the topic!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, _} = error ->
        error
    end
  end
end
