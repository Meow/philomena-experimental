defmodule PhilomenaWeb.Image.ReadController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    with {:ok, _image} <- Images.mark_image_read(conn.assigns.current_user, params["image_id"]) do
      send_resp(conn, :ok, "")
    end
  end
end
