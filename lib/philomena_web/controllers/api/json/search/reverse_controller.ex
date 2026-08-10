defmodule PhilomenaWeb.Api.Json.Search.ReverseController do
  use PhilomenaWeb, :controller

  alias Philomena.DuplicateReports
  alias Philomena.Interactions

  plug PhilomenaWeb.ScraperCachePlug
  plug PhilomenaWeb.ScraperPlug, params_key: "image", params_name: "image"

  def create(conn, %{"image" => image_params}) do
    {images, total} =
      image_params
      |> Map.put("distance", conn.params["distance"])
      |> Map.put("limit", conn.params["limit"])
      |> DuplicateReports.execute_search_query()
      |> case do
        {:ok, images} ->
          {images, images.total_entries}

        {:error, _changeset} ->
          {[], 0}
      end

    interactions = Interactions.user_interactions(conn.assigns.actor, images)

    conn
    |> put_view(PhilomenaWeb.Api.Json.ImageView)
    |> render("index.json",
      images: images,
      total: total,
      interactions: interactions
    )
  end
end
