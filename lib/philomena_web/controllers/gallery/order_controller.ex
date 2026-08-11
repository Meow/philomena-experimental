defmodule PhilomenaWeb.Gallery.OrderController do
  use PhilomenaWeb, :controller

  alias Philomena.Galleries

  action_fallback PhilomenaWeb.FallbackController

  def update(conn, %{"gallery_id" => gallery_id, "image_ids" => image_ids})
      when is_list(image_ids) do
    case Galleries.reorder_gallery(conn.assigns.actor, gallery_id, image_ids) do
      {:ok, _gallery} ->
        json(conn, %{})

      {:error, :invalid_order} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "image_ids must exactly match the gallery's images"})

      {:error, _reason} = error ->
        error
    end
  end
end
