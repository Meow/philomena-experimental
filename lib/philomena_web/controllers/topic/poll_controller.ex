defmodule PhilomenaWeb.Topic.PollController do
  use PhilomenaWeb, :controller

  alias Philomena.Polls

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, %{"forum_id" => forum_slug, "topic_id" => topic_slug}) do
    with {:ok, form} <-
           Polls.load_poll_for_edit(conn.assigns.actor, forum_slug, topic_slug) do
      render(conn, "edit.html",
        title: "Editing Poll",
        forum: form.forum,
        topic: form.topic,
        poll: form.poll,
        changeset: form.changeset
      )
    end
  end

  def update(conn, %{"forum_id" => forum_slug, "topic_id" => topic_slug, "poll" => poll_params}) do
    case Polls.update_poll(conn.assigns.actor, forum_slug, topic_slug, poll_params) do
      {:ok, result} ->
        conn
        |> put_flash(:info, "Poll successfully updated.")
        |> redirect(to: ~p"/forums/#{result.forum}/topics/#{result.topic}")

      {:error, %Philomena.Polls.PollForm{} = form} ->
        render(conn, "edit.html",
          forum: form.forum,
          topic: form.topic,
          poll: form.poll,
          changeset: form.changeset
        )

      error ->
        error
    end
  end
end
