defmodule PhilomenaWeb.ForumController do
  use PhilomenaWeb, :controller

  alias Philomena.Forums

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, _params) do
    {forums, topic_count} = Forums.load_forum_index(conn.assigns.current_user)

    render(conn, "index.html", title: "Forums", forums: forums, topic_count: topic_count)
  end

  def show(conn, %{"id" => short_name}) do
    with {:ok, {forum, topics, watching}} <-
           Forums.load_forum_show(conn.assigns.current_user, short_name, conn.assigns.scrivener) do
      render(conn, "show.html",
        title: forum.name,
        forum: forum,
        watching: watching,
        topics: topics
      )
    end
  end
end
