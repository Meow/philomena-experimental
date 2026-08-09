defmodule PhilomenaWeb.Topic.Poll.VoteController do
  use PhilomenaWeb, :controller

  alias Philomena.PollVotes

  # Builds the `:actor` struct (with the request's ban) that create's
  # write-access check consumes; only create needs it.

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, %{"forum_id" => forum_slug, "topic_id" => topic_slug}) do
    with {:ok, options} <-
           PollVotes.list_votes(conn.assigns.actor, forum_slug, topic_slug) do
      render(conn, "index.html", layout: false, options: options)
    end
  end

  def create(conn, %{"forum_id" => forum_slug, "topic_id" => topic_slug} = params) do
    case PollVotes.create_votes(conn.assigns.actor, forum_slug, topic_slug, params["poll"]) do
      {:ok, result} ->
        conn
        |> put_flash(:info, "Your vote has been recorded.")
        |> redirect(to: ~p"/forums/#{result.forum}/topics/#{result.topic}")

      {:error, %Philomena.PollVotes.VoteForm{} = form} ->
        conn
        |> put_flash(:error, "Your vote was not recorded.")
        |> redirect(to: ~p"/forums/#{form.forum}/topics/#{form.topic}")

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, %{"forum_id" => forum_slug, "topic_id" => topic_slug, "id" => vote_id}) do
    case PollVotes.delete_vote(conn.assigns.actor, forum_slug, topic_slug, vote_id) do
      {:ok, result} ->
        conn
        |> put_flash(:info, "Vote successfully removed.")
        |> redirect(to: ~p"/forums/#{result.forum}/topics/#{result.topic}")

      {:error, _} = error ->
        error
    end
  end
end
