defmodule PhilomenaWeb.Image.DestroyController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id}) do
    case Images.create_image_destruction(conn.assigns.actor, image_id) do
      {:ok, _destruction} ->
        conn
        |> put_flash(:info, "Image contents destroyed.")
        |> redirect(to: ~p"/images/#{image_id}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to destroy image.")
        |> redirect(to: ~p"/images/#{image_id}")

      error ->
        error
    end
  end
end
