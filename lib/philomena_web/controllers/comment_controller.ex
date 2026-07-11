defmodule PhilomenaWeb.CommentController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Comments

  def index(conn, params) do
    cq = params["cq"] || "created_at.gte:1 week ago"

    # The template reads the effective query back out of conn.params["cq"],
    # so the default must be written there when the parameter is absent.
    params = Map.put(conn.params, "cq", cq)
    conn = Map.put(conn, :params, params)

    user = conn.assigns.current_user
    filter = conn.assigns.current_filter

    case Comments.search_comments(user, filter, cq, conn.assigns.pagination) do
      {:ok, comments} ->
        rendered = MarkdownRenderer.render_collection(comments.entries, conn)
        comments = %{comments | entries: Enum.zip(rendered, comments.entries)}

        render(conn, "index.html", title: "Comments", comments: comments)

      {:error, msg} ->
        render(conn, "index.html", title: "Comments", error: msg, comments: [])
    end
  end
end
