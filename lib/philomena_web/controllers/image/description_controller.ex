defmodule PhilomenaWeb.Image.DescriptionController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.UserAttributionPlug

  def update(conn, %{"image" => image_params} = params) do
    case Images.update_description(conn.assigns.actor, params["image_id"], image_params) do
      {:ok, {image, old_description}} ->
        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:description_update",
          %{image_id: image.id, added: image.description, removed: old_description}
        )

        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:update",
          PhilomenaWeb.Api.Json.ImageView.render("show.json", %{image: image, interactions: []})
        )

        Images.reindex_image(image)

        body = MarkdownRenderer.render_one(%{body: image.description}, conn)

        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_description.html", layout: false, image: image, body: body)

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "_form.html", layout: false, image: changeset.data, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end
end
