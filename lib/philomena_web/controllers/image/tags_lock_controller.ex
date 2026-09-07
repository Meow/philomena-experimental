defmodule PhilomenaWeb.Image.TagsLockController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id}) do
    with {:ok, _tags_lock} <-
           Images.update_image_tags_lock(conn.assigns.actor, image_id, %{tags_locked: true}) do
      conn
      |> put_flash(:info, "Successfully locked tags.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end

  def delete(conn, %{"image_id" => image_id}) do
    with {:ok, _tags_lock} <-
           Images.update_image_tags_lock(conn.assigns.actor, image_id, %{tags_locked: false}) do
      conn
      |> put_flash(:info, "Successfully unlocked tags.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
