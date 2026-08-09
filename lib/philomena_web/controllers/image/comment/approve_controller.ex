defmodule PhilomenaWeb.Image.Comment.ApproveController do
  use PhilomenaWeb, :controller

  alias Philomena.Comments

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id, "comment_id" => comment_id}) do
    with {:ok, comment} <- Comments.approve_comment(conn.assigns.actor, image_id, comment_id) do
      conn
      |> put_flash(:info, "Comment has been approved.")
      |> redirect(to: ~p"/images/#{comment.image_id}" <> "#comment_#{comment.id}")
    end
  end
end
