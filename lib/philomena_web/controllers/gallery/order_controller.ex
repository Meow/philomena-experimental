defmodule PhilomenaWeb.Gallery.OrderController do
  use PhilomenaWeb, :controller

  alias Philomena.Galleries

  action_fallback PhilomenaWeb.FallbackController

  def update(conn, %{"gallery_id" => gallery_id, "image_ids" => image_ids})
      when is_list(image_ids) do
    with {:ok, _gallery} <- Galleries.reorder_gallery(conn.assigns.actor, gallery_id, image_ids) do
      json(conn, %{})
    end
  end
end
