defmodule PhilomenaWeb.Gallery.ImageController do
  use PhilomenaWeb, :controller

  alias Philomena.Galleries

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"gallery_id" => gallery_id} = params) do
    case Galleries.add_image_to_gallery(conn.assigns.actor, gallery_id, params["image_id"]) do
      {:ok, _gallery} ->
        json(conn, %{})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:conflict)
        |> json(%{})

      error ->
        error
    end
  end

  def delete(conn, %{"gallery_id" => gallery_id} = params) do
    with {:ok, _gallery} <-
           Galleries.remove_image_from_gallery(conn.assigns.actor, gallery_id, params["image_id"]) do
      json(conn, %{})
    end
  end
end
