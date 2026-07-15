defmodule PhilomenaWeb.Image.Comment.HistoryController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Comments

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, %{"image_id" => image_id, "comment_id" => comment_id}) do
    with {:ok, {image, comment, versions}} <-
           Comments.comment_history(conn.assigns.actor, image_id, comment_id) do
      render(conn, "index.html",
        title: "Comment History for comment #{comment.id} on image #{image.id}",
        comment: comment,
        versions: MarkdownRenderer.render_version_diffs(versions)
      )
    end
  end
end
