defmodule PhilomenaWeb.Image.VoteController do
  use PhilomenaWeb, :controller

  alias Philomena.Images.Image
  alias Philomena.Images

  plug :load_interaction_image
  plug PhilomenaWeb.FilterForcedUsersPlug

  def create(conn, params) do
    case parse_up(params["up"]) do
      {:ok, up} ->
        case Images.create_vote(conn.assigns.image, conn.assigns.actor, up) do
          {:ok, image} ->
            json(conn, Image.interaction_data(image))

          {:error, :interaction_failed} ->
            conn
            |> put_status(409)
            |> json(%{})
        end

      :error ->
        conn
        |> put_status(400)
        |> json(%{})
    end
  end

  def delete(conn, _params) do
    case Images.delete_vote(conn.assigns.image, conn.assigns.actor) do
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

  defp parse_up(up) when up in [true, "true"], do: {:ok, true}
  defp parse_up(up) when up in [false, "false"], do: {:ok, false}
  defp parse_up(_up), do: :error
end
