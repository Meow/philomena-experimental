defmodule PhilomenaWeb.Image.DestroyController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    case Images.destroy_image(conn.assigns.actor, params["image_id"]) do
      {:ok, image} ->
        conn
        |> put_flash(:info, "Image contents destroyed.")
        |> redirect(to: ~p"/images/#{image}")

      {:error, :not_deleted} ->
        conn
        |> put_flash(:error, "Cannot destroy a non-deleted image!")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to destroy image.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, _} = error ->
        error
    end
  end
end
