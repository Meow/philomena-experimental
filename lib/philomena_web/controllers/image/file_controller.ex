defmodule PhilomenaWeb.Image.FileController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.ScraperPlug, params_name: "image", params_key: "image"

  def update(conn, %{"image_id" => image_id} = params) do
    upload = PhilomenaMedia.Upload.cast(params["image"], "image")

    case Images.update_image_file(conn.assigns.actor, image_id, upload) do
      {:ok, _file} ->
        conn
        |> put_flash(:info, "Successfully updated file.")
        |> redirect(to: ~p"/images/#{image_id}")

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(:error, "Failed to update file!")
        |> redirect(to: ~p"/images/#{image_id}")

      error ->
        error
    end
  end
end
