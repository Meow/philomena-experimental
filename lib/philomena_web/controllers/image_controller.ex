defmodule PhilomenaWeb.ImageController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.NotificationCountPlug
  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Images
  alias Philomena.Interactions

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.LimitPlug,
       [time: 5, error: "You may only upload images once every 5 seconds."]
       when action in [:create]

  plug :load_image when action in [:show]

  plug PhilomenaWeb.UserAttributionPlug when action in [:new, :create]
  plug PhilomenaWeb.CaptchaPlug when action in [:new, :show, :create]
  plug PhilomenaWeb.CheckCaptchaPlug when action in [:create]

  plug PhilomenaWeb.ScraperPlug,
       [params_name: "image", params_key: "image"] when action in [:create]

  plug PhilomenaWeb.AdvertPlug when action in [:show]

  def index(conn, _params) do
    images = Images.load_image_index(ImageScope.search_scope(conn))

    interactions = Interactions.user_interactions(images, conn.assigns.current_user)

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
      Images.load_image_page(
        conn.assigns.current_user,
        image,
        conn.assigns.comment_scrivener
      )

    # The page load clears the image notification, so the header ticker must
    # be re-read afterwards.
    conn = NotificationCountPlug.call(conn)

    rendered = MarkdownRenderer.render_collection(page.comments.entries, conn)
    comments = %{page.comments | entries: Enum.zip(page.comments.entries, rendered)}

    description = MarkdownRenderer.render_one(%{body: image.description}, conn)

    assigns = [
      image: image,
      comments: comments,
      image_changeset: page.image_changeset,
      comment_changeset: page.comment_changeset,
      user_galleries: page.user_galleries,
      description: description,
      interactions: page.interactions,
      watching: page.watching,
      layout_class: "layout--wide",
      title: "##{image.id} - #{Images.tag_list(image)}"
    ]

    if image.hidden_from_users do
      render(conn, "deleted.html", assigns)
    else
      render(conn, "show.html", assigns)
    end
  end

  def new(conn, _params) do
    with {:ok, changeset} <- Images.load_new_image(conn.assigns.actor) do
      render(conn, "new.html", title: "New Image", changeset: changeset)
    end
  end

  def create(conn, params) do
    case Images.upload_image(conn.assigns.actor, params["image"]) do
      {:ok, %{image: image}} ->
        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:create",
          PhilomenaWeb.Api.Json.ImageView.render("show.json", %{image: image, interactions: []})
        )

        conn
        |> put_flash(:info, "Image created successfully.")
        |> redirect(to: ~p"/images/#{image}")

      {:error, :image, changeset, _} ->
        render(conn, "new.html", changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  defp load_image(conn, _opts) do
    case Images.load_image_for_show(conn.assigns.current_user, conn.params["id"]) do
      {:ok, %{image: image} = loaded} ->
        conn
        |> assign(:image, image)
        |> assign(:tag_change_count, loaded.tag_change_count)
        |> assign(:tag_change_tag_count, loaded.tag_change_tag_count)
        |> assign(:source_change_count, loaded.source_change_count)

      {:duplicate_of, image} ->
        conn
        |> put_flash(
          :info,
          "The image you were looking for has been marked a duplicate of the image below"
        )
        |> redirect(to: ~p"/images/#{image.duplicate_id}")
        |> halt()

      {:error, :not_found} = error ->
        conn
        |> PhilomenaWeb.FallbackController.call(error)
        |> halt()
    end
  end
end
