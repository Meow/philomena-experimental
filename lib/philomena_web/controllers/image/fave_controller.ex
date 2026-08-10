defmodule PhilomenaWeb.Image.FaveController do
  use PhilomenaWeb, :controller

  alias Philomena.Images.Image
  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id}) do
    case Images.create_fave(conn.assigns.actor, image_id) do
      {:ok, image} ->
        json(conn, Image.interaction_data(image))

      {:error, :interaction_failed} ->
        conn
        |> put_status(409)
        |> json(%{})

      {:error, _reason} = error ->
        error
    end
  end

  def delete(conn, %{"image_id" => image_id}) do
    case Images.delete_fave(conn.assigns.actor, image_id) do
      {:ok, image} ->
        json(conn, Image.interaction_data(image))

      {:error, :interaction_failed} ->
        conn
        |> put_status(409)
        |> json(%{})

      {:error, _reason} = error ->
        error
    end
  end
end
