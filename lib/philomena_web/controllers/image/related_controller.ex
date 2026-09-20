defmodule PhilomenaWeb.Image.RelatedController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.ImageView
  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    with {:ok, {image, images}} <-
           Images.list_related_images(
             conn.assigns.actor,
             ImageScope.search_scope(conn),
             params["image_id"],
             conn.assigns.image_filter
           ) do
      render(conn, "index.html",
        title: "##{image.id} - Related Images",
        layout_class: "layout--wide",
        image: image,
        images: images,
        interactions: ImageView.client_interactions(images)
      )
    end
  end
end
