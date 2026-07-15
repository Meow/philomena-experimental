defmodule PhilomenaWeb.Topic.PollController do
  use PhilomenaWeb, :controller

  alias Philomena.Polls

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, %{"forum_id" => forum_slug, "topic_id" => topic_slug}) do
    with {:ok, {forum, topic, poll, changeset}} <-
           Polls.load_poll_for_edit(conn.assigns.actor, forum_slug, topic_slug) do
      render(conn, "edit.html",
        title: "Editing Poll",
        forum: forum,
        topic: topic,
        poll: poll,
        changeset: changeset
      )
    end
  end

  def update(conn, %{"forum_id" => forum_slug, "topic_id" => topic_slug, "poll" => poll_params}) do
    case Polls.update_poll(conn.assigns.actor, forum_slug, topic_slug, poll_params) do
      {:ok, {forum, topic}} ->
        conn
        |> put_flash(:info, "Poll successfully updated.")
        |> redirect(to: ~p"/forums/#{forum}/topics/#{topic}")

      {:error, forum, topic, changeset} ->
        render(conn, "edit.html", forum: forum, topic: topic, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end
end
