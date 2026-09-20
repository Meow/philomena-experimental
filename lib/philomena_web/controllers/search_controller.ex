defmodule PhilomenaWeb.SearchController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.TagInfoRenderer
  alias Philomena.Images
  alias PhilomenaWeb.ImageView

  def index(conn, params) do
    case Images.query_image_previews(
           conn.assigns.actor,
           ImageScope.search_scope(conn),
           conn.assigns.image_filter
         ) do
      {:ok, %{images: images, tags: tags}} ->
        render(conn, "index.html",
          title: "Searching for #{params["q"]}",
          images: images,
          tags: TagInfoRenderer.render_tag_info(tags, conn),
          search_query: params["q"],
          interactions: ImageView.client_interactions(images),
          layout_class: "layout--wide"
        )

      {:error, msg} ->
        render(conn, "index.html",
          title: "Searching for #{params["q"]}",
          images: [],
          tags: [],
          error: msg,
          search_query: params["q"]
        )
    end
  end
end
