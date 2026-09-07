defmodule PhilomenaWeb.Image.HashController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def delete(conn, %{"image_id" => image_id}) do
    with {:ok, _hash} <- Images.delete_image_hash(conn.assigns.actor, image_id) do
      conn
      |> put_flash(:info, "Successfully cleared hash.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
