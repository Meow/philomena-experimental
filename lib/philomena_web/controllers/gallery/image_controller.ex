defmodule PhilomenaWeb.Gallery.ImageController do
  use PhilomenaWeb, :controller

  alias Philomena.Galleries

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.UserAttributionPlug

  def create(conn, params) do
    conn.assigns.actor
    |> Galleries.add_image_to_gallery(params["gallery_id"], params["image_id"])
    |> respond(conn)
  end

  def delete(conn, params) do
    conn.assigns.actor
    |> Galleries.remove_image_from_gallery(params["gallery_id"], params["image_id"])
    |> respond(conn)
  end

  defp respond({:ok, _result}, conn), do: json(conn, %{})

  defp respond({:error, reason}, _conn) when reason in [:ban, :unauthorized, :not_found],
    do: {:error, reason}

  defp respond(_error, conn), do: conn |> put_status(:bad_request) |> json(%{})
end
