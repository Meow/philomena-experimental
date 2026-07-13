defmodule PhilomenaWeb.Api.Json.ImageController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias Philomena.Interactions
  import PhilomenaWeb.Api.Json.NotFound

  plug PhilomenaWeb.ScraperCachePlug
  plug PhilomenaWeb.ApiRequireAuthorizationPlug when action in [:create]
  plug PhilomenaWeb.UserAttributionPlug when action in [:create]

  plug PhilomenaWeb.ScraperPlug,
       [params_name: "image", params_key: "image"] when action in [:create]

  def show(conn, %{"id" => id}) do
    case Images.load_image(id) do
      {:ok, image} ->
        interactions = Interactions.user_interactions([image], conn.assigns.current_user)

        render(conn, "show.json", image: image, interactions: interactions)

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  def create(conn, %{"image" => image_params}) do
    attributes = conn.assigns.attributes

    case Images.create_image(attributes, image_params) do
      {:ok, %{image: image}} ->
        image = Images.preload_created_image(image)

        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:create",
          PhilomenaWeb.Api.Json.ImageView.render("show.json", %{image: image, interactions: []})
        )

        render(conn, "show.json", image: image, interactions: [])

      {:error, :image, changeset, _} ->
        conn
        |> put_status(:bad_request)
        |> render("error.json", changeset: changeset)
    end
  end
end
