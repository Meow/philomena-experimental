defmodule PhilomenaWeb.Image.DeleteController do
  use PhilomenaWeb, :controller

  # N.B.: this would be Image.Hide, because it hides the image, but that is
  # taken by the user action

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id} = params) do
    case Images.create_image_hide(conn.assigns.actor, image_id, params["hide"]) do
      {:ok, _image} ->
        conn
        |> put_flash(:info, "Image successfully deleted.")
        |> redirect(to: ~p"/images/#{image_id}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to delete image.")
        |> redirect(to: ~p"/images/#{image_id}")

      error ->
        error
    end
  end

  def update(conn, %{"image_id" => image_id} = params) do
    case Images.update_image_hide(conn.assigns.actor, image_id, params["hide"]) do
      {:ok, _image} ->
        conn
        |> put_flash(:info, "Deletion reason updated.")
        |> redirect(to: ~p"/images/#{image_id}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Couldn't update deletion reason.")
        |> redirect(to: ~p"/images/#{image_id}")

      error ->
        error
    end
  end

  def delete(conn, %{"image_id" => image_id}) do
    case Images.delete_image_hide(conn.assigns.actor, image_id) do
      {:ok, _image} ->
        conn
        |> put_flash(:info, "Image successfully restored.")
        |> redirect(to: ~p"/images/#{image_id}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to restore image.")
        |> redirect(to: ~p"/images/#{image_id}")

      error ->
        error
    end
  end
end
