defmodule PhilomenaWeb.Image.CommentLockController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id}) do
    with {:ok, _comment_lock_form} <-
           Images.update_image_comments_lock(conn.assigns.actor, image_id, %{
             comments_locked: true
           }) do
      conn
      |> put_flash(:info, "Successfully locked comments.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end

  def delete(conn, %{"image_id" => image_id}) do
    with {:ok, _comment_lock_form} <-
           Images.update_image_comments_lock(conn.assigns.actor, image_id, %{
             comments_locked: false
           }) do
      conn
      |> put_flash(:info, "Successfully unlocked comments.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
