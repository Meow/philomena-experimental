defmodule PhilomenaWeb.Image.DescriptionController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def update(conn, %{"image_id" => image_id} = params) do
    case Images.update_image_description(conn.assigns.actor, image_id, params["description"]) do
      {:ok, description} ->
        body = MarkdownRenderer.render_one(%{body: description.description}, conn)

        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_description.html",
          layout: false,
          description: description.description,
          body: body,
          editable?: true
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "_form.html",
          layout: false,
          changeset: changeset,
          action: ~p"/images/#{image_id}/description"
        )

      error ->
        error
    end
  end
end
