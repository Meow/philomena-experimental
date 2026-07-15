defmodule PhilomenaWeb.Image.FeatureController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    case Images.feature_image(conn.assigns.actor, params["image_id"]) do
      {:ok, _feature} ->
        conn
        |> put_flash(:info, "Image marked as featured image.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, :deleted} ->
        conn
        |> put_flash(:error, "Cannot feature a deleted image.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, _} = error ->
        error
    end
  end
end
