defmodule PhilomenaWeb.Topic.LockController do
  use PhilomenaWeb, :controller

  alias Philomena.Topics

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"topic" => topic_params} = params) do
    case Topics.lock_topic(
           conn.assigns.current_user,
           params["forum_id"],
           params["topic_id"],
           topic_params
         ) do
      {:ok, {forum, topic}} ->
        conn
        |> put_flash(:info, "Topic successfully locked!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, forum, topic} ->
        conn
        |> put_flash(:error, "Unable to lock the topic!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, params) do
    case Topics.unlock_topic(
           conn.assigns.current_user,
           params["forum_id"],
           params["topic_id"]
         ) do
      {:ok, {forum, topic}} ->
        conn
        |> put_flash(:info, "Topic successfully unlocked!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, forum, topic} ->
        conn
        |> put_flash(:error, "Unable to unlock the topic!")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, _} = error ->
        error
    end
  end
end
