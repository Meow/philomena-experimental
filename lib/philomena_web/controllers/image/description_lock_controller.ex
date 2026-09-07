defmodule PhilomenaWeb.Image.DescriptionLockController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id}) do
    with {:ok, _description_lock} <-
           Images.update_image_description_lock(conn.assigns.actor, image_id, %{
             description_locked: true
           }) do
      conn
      |> put_flash(:info, "Successfully locked description.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end

  def delete(conn, %{"image_id" => image_id}) do
    with {:ok, _description_lock} <-
           Images.update_image_description_lock(conn.assigns.actor, image_id, %{
             description_locked: false
           }) do
      conn
      |> put_flash(:info, "Successfully unlocked description.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
