defmodule PhilomenaWeb.Image.SourceChangeController do
  use PhilomenaWeb, :controller

  alias Philomena.SourceChanges
  alias Philomena.SourceChanges.SourceChangePage

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    with {:ok, %SourceChangePage{target: image, source_changes: source_changes}} <-
           SourceChanges.image_source_changes(
             conn.assigns.actor,
             params["image_id"],
             conn.assigns.scrivener
           ) do
      render(conn, "index.html",
        title: "Source Changes on Image #{image.id}",
        image: image,
        source_changes: source_changes
      )
    end
  end
end
