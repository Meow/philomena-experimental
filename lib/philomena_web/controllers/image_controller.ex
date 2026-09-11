defmodule PhilomenaWeb.ImageController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias Philomena.Interactions
  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.ImageView
  alias PhilomenaWeb.MarkdownRenderer
  alias PhilomenaWeb.NotificationCountPlug
  alias PhilomenaWeb.RateLimitedResponse

  action_fallback PhilomenaWeb.FallbackController

  plug :load_image when action in [:show]

  plug PhilomenaWeb.CaptchaPlug when action in [:new, :show, :create]
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  plug PhilomenaWeb.ScraperPlug,
       [params_name: "image", params_key: "image"] when action in [:create]

  plug PhilomenaWeb.AdvertPlug when action in [:show]

  def index(conn, _params) do
    images = Images.list_images(conn.assigns.actor, ImageScope.search_scope(conn))

    interactions = Interactions.user_interactions(conn.assigns.actor, images)

    render(conn, "index.html",
      title: "Images",
      layout_class: "layout--wide",
      images: images,
      interactions: interactions,
      scope: ImageScope.scope(conn)
    )
  end

  def show(conn, %{"id" => _id}) do
    image = conn.assigns.image

    page =
      Images.show_image_page(
        conn.assigns.actor,
        image,
        conn.assigns.comment_scrivener
      )

    # The page load clears the image notification, so the header ticker must
    # be re-read afterwards.
    conn = NotificationCountPlug.call(conn)

    page =
      update_in(page.comments.comments.entries, fn comments ->
        rendered = MarkdownRenderer.render_collection(comments, conn)

        Enum.zip(comments, rendered)
      end)

    rendered_description = MarkdownRenderer.render_one(page.description, conn)

    {_image, conn} = pop_in(conn.assigns[:image])

    assigns = [
      page: page,
      rendered_description: rendered_description,
      interactions: ImageView.client_interactions(page),
      layout_class: "layout--wide",
      title: "##{page.metadata.id} - #{ImageView.display_tag_list(page.tags)}"
    ]

    if page.moderation_metadata.hidden_from_users? do
      render(conn, "deleted.html", assigns)
    else
      render(conn, "show.html", assigns)
    end
  end

  def new(conn, _params) do
    with {:ok, changeset} <- Images.new_image(conn.assigns.actor) do
      render(conn, "new.html", title: "New Image", changeset: changeset)
    end
  end

  def create(conn, params) do
    upload = PhilomenaMedia.Upload.cast(params["image"], "image")

    case Images.create_image(conn.assigns.actor, params["image"], upload) do
      {:ok, %{image: image}} ->
        conn
        |> put_flash(:info, "Image created successfully.")
        |> redirect(to: ~p"/images/#{image}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)

      {:error, :rate_limited} ->
        RateLimitedResponse.call(conn, "You may only upload images once every 5 seconds.")

      error ->
        error
    end
  end

  defp load_image(conn, _opts) do
    case Images.show_image(conn.assigns.actor, conn.params["id"]) do
      {:ok, image} ->
        assign(conn, :image, image)

      {:duplicate_of, target_image_id} ->
        conn
        |> put_flash(
          :info,
          "The image you were looking for has been marked a duplicate of the image below"
        )
        |> redirect(to: ~p"/images/#{target_image_id}")
        |> halt()

      {:error, _not_visible_or_missing} = error ->
        conn
        |> PhilomenaWeb.FallbackController.call(error)
        |> halt()
    end
  end
end
