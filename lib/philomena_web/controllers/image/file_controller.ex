defmodule PhilomenaWeb.Image.FileController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.ScraperPlug, params_name: "image", params_key: "image"

  def update(conn, %{"image" => image_params} = params) do
    case Images.update_file(conn.assigns.actor, params["image_id"], image_params) do
      {:ok, image} ->
        conn
        |> put_flash(:info, "Successfully updated file.")
        |> redirect(to: ~p"/images/#{image}")

      {:error, :deleted} ->
        conn
        |> put_flash(:error, "Cannot replace a deleted image.")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to update file!")
        |> redirect(to: ~p"/images/#{params["image_id"]}")

      {:error, _} = error ->
        error
    end
  end
end
