defmodule PhilomenaWeb.Gallery.ReadController do
  use PhilomenaWeb, :controller

  alias Philomena.Galleries

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    with {:ok, _gallery} <-
           Galleries.mark_gallery_read(conn.assigns.current_user, params["gallery_id"]) do
      send_resp(conn, :ok, "")
    end
  end
end
