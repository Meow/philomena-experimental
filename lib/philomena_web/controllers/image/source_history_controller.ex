defmodule PhilomenaWeb.Image.SourceHistoryController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def delete(conn, %{"image_id" => image_id}) do
    with {:ok, _source_history} <-
           Images.delete_image_source_history(conn.assigns.actor, image_id) do
      conn
      |> put_flash(:info, "Successfully deleted source history.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
