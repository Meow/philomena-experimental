defmodule PhilomenaWeb.Image.FaveController do
  use PhilomenaWeb, :controller

  alias Philomena.Images.Image
  alias Philomena.Images

  plug PhilomenaWeb.UserAttributionPlug
  plug :load_interaction_image
  plug PhilomenaWeb.FilterForcedUsersPlug

  def create(conn, _params) do
    case Images.create_fave(conn.assigns.image, conn.assigns.current_user) do
      {:ok, image} ->
        json(conn, Image.interaction_data(image))

      {:error, :interaction_failed} ->
        conn
        |> put_status(409)
        |> json(%{})
    end
  end

  def delete(conn, _params) do
    case Images.delete_fave(conn.assigns.image, conn.assigns.current_user) do
      {:ok, image} ->
        json(conn, Image.interaction_data(image))

      {:error, :interaction_failed} ->
        conn
        |> put_status(409)
        |> json(%{})
    end
  end

  # Loads and authorizes the image (and rejects banned actors) before the
  # forced-filter check, which needs the image with its tags preloaded.
  defp load_interaction_image(conn, _opts) do
    case Images.load_image_for_interaction(conn.assigns.actor, conn.params["image_id"]) do
      {:ok, image} ->
        assign(conn, :image, image)

      error ->
        conn
        |> PhilomenaWeb.FallbackController.call(error)
        |> halt()
    end
  end
end
