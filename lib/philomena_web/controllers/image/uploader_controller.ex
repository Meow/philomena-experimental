defmodule PhilomenaWeb.Image.UploaderController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def update(conn, %{"image_id" => image_id} = params) do
    case Images.update_image_uploader(conn.assigns.actor, image_id, params["uploader"]) do
      {:ok, _uploader} ->
        conn
        |> put_flash(:info, "Successfully updated uploader.")
        |> redirect(to: ~p"/images/#{image_id}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to update uploader!")
        |> redirect(to: ~p"/images/#{image_id}")

      error ->
        error
    end
  end
end
