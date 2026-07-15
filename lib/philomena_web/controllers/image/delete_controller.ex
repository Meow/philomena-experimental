defmodule PhilomenaWeb.Image.DeleteController do
  use PhilomenaWeb, :controller

  # N.B.: this would be Image.Hide, because it hides the image, but that is
  # taken by the user action

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image" => image_params} = params) do
    case Images.hide_image(conn.assigns.actor, params["image_id"], image_params) do
      {:ok, _image} ->
        conn
        |> put_flash(:info, "Image successfully deleted.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, :hide_failed} ->
        conn
        |> put_flash(:error, "Failed to delete image.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, _} = error ->
        error
    end
  end

  def update(conn, %{"image" => image_params} = params) do
    case Images.update_hide_reason(conn.assigns.actor, params["image_id"], image_params) do
      {:ok, _image} ->
        conn
        |> put_flash(:info, "Deletion reason updated.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, :not_deleted} ->
        conn
        |> put_flash(:error, "Cannot change deletion reason on a non-deleted image!")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Couldn't update deletion reason.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, params) do
    with {:ok, _image} <- Images.unhide_image(conn.assigns.actor, params["image_id"]) do
      conn
      |> put_flash(:info, "Image successfully restored.")
      |> redirect(to: ~p"/images/#{params["image_id"]}")
    end
  end
end
