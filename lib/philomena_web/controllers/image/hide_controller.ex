defmodule PhilomenaWeb.Image.HideController do
  use PhilomenaWeb, :controller

  alias Philomena.Images.Image
  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.UserAttributionPlug

  def create(conn, params) do
    case Images.create_image_hide(conn.assigns.actor, params["image_id"]) do
      {:ok, image} ->
        json(conn, Image.interaction_data(image))

      {:error, :hide_failed} ->
        conn
        |> put_status(409)
        |> json(%{})

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, params) do
    case Images.delete_image_hide(conn.assigns.actor, params["image_id"]) do
      {:ok, image} ->
        json(conn, Image.interaction_data(image))

      {:error, :hide_failed} ->
        conn
        |> put_status(409)
        |> json(%{})

      {:error, _} = error ->
        error
    end
  end
end
