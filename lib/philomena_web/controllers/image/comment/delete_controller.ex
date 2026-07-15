defmodule PhilomenaWeb.Image.Comment.DeleteController do
  use PhilomenaWeb, :controller

  alias Philomena.Comments
  alias Philomena.Comments.Comment

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"comment_id" => comment_id}) do
    case Comments.destroy_comment(conn.assigns.actor, comment_id) do
      {:ok, comment} ->
        conn
        |> put_flash(:info, "Comment successfully destroyed!")
        |> redirect(to: ~p"/images/#{comment.image_id}" <> "#comment_#{comment.id}")

      {:error, %Comment{} = comment} ->
        conn
        |> put_flash(:error, "Unable to destroy comment!")
        |> redirect(to: ~p"/images/#{comment.image_id}" <> "#comment_#{comment.id}")

      {:error, _} = error ->
        error
    end
  end
end
