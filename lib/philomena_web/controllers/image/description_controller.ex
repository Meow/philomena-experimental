defmodule PhilomenaWeb.Image.DescriptionController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def update(conn, %{"image_id" => image_id} = params) do
    case Images.update_image_description(
           conn.assigns.actor,
           image_id,
           params["description_input"]
         ) do
      {:ok, %{description: description}} ->
        rendered = MarkdownRenderer.render_one(description, conn)

        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_description.html",
          layout: false,
          image_id: image_id,
          description: description,
          rendered: rendered
        )

      {:error, %{changeset: changeset}} ->
        render(conn, "_form.html",
          layout: false,
          image_id: image_id,
          changeset: changeset
        )

      error ->
        error
    end
  end
end
