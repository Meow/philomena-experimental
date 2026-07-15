defmodule PhilomenaWeb.Image.DescriptionLockController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    with {:ok, image} <-
           Images.set_description_locked(conn.assigns.actor, params["image_id"], true) do
      conn
      |> put_flash(:info, "Successfully locked description.")
      |> redirect(to: ~p"/images/#{image}")
    end
  end

  def delete(conn, params) do
    with {:ok, image} <-
           Images.set_description_locked(conn.assigns.actor, params["image_id"], false) do
      conn
      |> put_flash(:info, "Successfully unlocked description.")
      |> redirect(to: ~p"/images/#{image}")
    end
  end
end
