defmodule PhilomenaWeb.Api.Json.Image.FeaturedController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias Philomena.Interactions
  import PhilomenaWeb.Api.Json.NotFound

  def show(conn, _params) do
    case Images.api_featured_image() do
      {:ok, image} ->
        interactions = Interactions.user_interactions([image], conn.assigns.current_user)

        conn
        |> put_view(PhilomenaWeb.Api.Json.ImageView)
        |> render("show.json", image: image, interactions: interactions)

      {:error, :not_found} ->
        not_found(conn)
    end
  end
end
