defmodule PhilomenaWeb.Image.Comment.HideController do
  use PhilomenaWeb, :controller

  alias Philomena.Comments
  alias Philomena.Comments.Comment

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"comment_id" => comment_id, "comment" => comment_params}) do
    case Comments.hide_comment(conn.assigns.actor, comment_id, comment_params) do
      {:ok, comment} ->
        conn
        |> put_flash(:info, "Comment successfully deleted!")
        |> redirect(to: ~p"/images/#{comment.image_id}" <> "#comment_#{comment.id}")

      {:error, %Comment{} = comment} ->
        conn
        |> put_flash(:error, "Unable to delete comment!")
        |> redirect(to: ~p"/images/#{comment.image_id}" <> "#comment_#{comment.id}")

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, %{"comment_id" => comment_id}) do
    case Comments.unhide_comment(conn.assigns.actor, comment_id) do
      {:ok, comment} ->
        conn
        |> put_flash(:info, "Comment successfully restored!")
        |> redirect(to: ~p"/images/#{comment.image_id}" <> "#comment_#{comment.id}")

      {:error, %Comment{} = comment} ->
        conn
        |> put_flash(:error, "Unable to restore comment!")
        |> redirect(to: ~p"/images/#{comment.image_id}" <> "#comment_#{comment.id}")

      {:error, _} = error ->
        error
    end
  end
end
