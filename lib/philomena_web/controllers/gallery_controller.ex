defmodule PhilomenaWeb.GalleryController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.NotificationCountPlug
  alias Philomena.Galleries

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.MapParameterPlug, [param: "gallery"] when action in [:index]

  def index(conn, params) do
    galleries = Galleries.load_gallery_index(params, conn.assigns.pagination)

    render(conn, "index.html",
      title: "Galleries",
      galleries: galleries,
      layout_class: "layout--wide"
    )
  end

  def show(conn, params) do
    case Galleries.load_gallery_page(
           conn.assigns.actor,
           ImageScope.search_scope(conn),
           params["id"]
         ) do
      {:ok, page} ->
        gallery_json = JSON.encode!(Enum.map(page.gallery_images, &elem(&1, 0).id))

        # The page load clears the gallery notification, so the header ticker
        # must be re-read afterwards.
        conn
        |> NotificationCountPlug.call([])
        |> assign(:clientside_data, gallery_images: gallery_json)
        |> render("show.html",
          title: "Showing Gallery",
          layout_class: "layout--wide",
          watching: page.watching,
          gallery: page.gallery,
          gallery_prev: page.gallery_prev,
          gallery_next: page.gallery_next,
          gallery_images: page.gallery_images,
          images: page.images,
          interactions: page.interactions
        )

      {:error, _} = error ->
        error
    end
  end

  def new(conn, _params) do
    with {:ok, changeset} <- Galleries.new_gallery(conn.assigns.actor) do
      render(conn, "new.html", title: "New Gallery", changeset: changeset)
    end
  end

  def create(conn, params) do
    case Galleries.create_gallery(conn.assigns.actor, params["gallery"]) do
      {:ok, gallery} ->
        conn
        |> put_flash(:info, "Gallery successfully created.")
        |> redirect(to: ~p"/galleries/#{gallery}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "new.html", changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  def edit(conn, params) do
    with {:ok, {gallery, changeset}} <-
           Galleries.load_gallery_for_edit(conn.assigns.actor, params["id"]) do
      render(conn, "edit.html", title: "Editing Gallery", gallery: gallery, changeset: changeset)
    end
  end

  def update(conn, params) do
    case Galleries.update_gallery(conn.assigns.actor, params["id"], params["gallery"]) do
      {:ok, gallery} ->
        conn
        |> put_flash(:info, "Gallery successfully updated.")
        |> redirect(to: ~p"/galleries/#{gallery}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", gallery: changeset.data, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, params) do
    with {:ok, _gallery} <- Galleries.delete_gallery(conn.assigns.actor, params["id"]) do
      conn
      |> put_flash(:info, "Gallery successfully destroyed.")
      |> redirect(to: ~p"/galleries")
    end
  end
end
