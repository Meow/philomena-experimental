defmodule PhilomenaWeb.TagController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.MarkdownRenderer
  alias Philomena.Tags

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    case Tags.search_tags(params, conn.assigns.pagination) do
      {:ok, tags} ->
        render(conn, "index.html", title: "Tags", tags: tags)

      {:error, msg} ->
        render(conn, "index.html", title: "Tags", tags: [], error: msg)
    end
  end

  def show(conn, params) do
    case Tags.load_tag_page(ImageScope.search_scope(conn), params["id"]) do
      {:ok, page} ->
        tag = page.tag
        body = MarkdownRenderer.render_one(%{body: tag.description || ""}, conn)

        dnp_bodies =
          MarkdownRenderer.render_collection(
            Enum.map(tag.dnp_entries, &%{body: &1.conditions || ""}),
            conn
          )

        dnp_entries = Enum.zip(dnp_bodies, tag.dnp_entries)

        conn_params = Map.put(conn.params, "q", page.search_query)
        conn = Map.put(conn, :params, conn_params)

        render(
          conn,
          "show.html",
          tag: tag,
          tags: [{tag, body, dnp_entries}],
          search_query: page.search_query,
          interactions: page.interactions,
          images: page.images,
          layout_class: "layout--wide",
          title: "#{tag.name} - Tags"
        )

      {:aliased_to, tag} ->
        conn
        |> put_flash(
          :info,
          "This tag (\"#{tag.name}\") has been aliased into the tag \"#{tag.aliased_tag.name}\"."
        )
        |> redirect(to: ~p"/tags/#{tag.aliased_tag}")

      {:error, _} = error ->
        error
    end
  end

  def edit(conn, params) do
    with {:ok, {tag, changeset}} <-
           Tags.load_tag_for_edit(conn.assigns.current_user, params["id"]) do
      render(conn, "edit.html", title: "Editing Tag", tag: tag, changeset: changeset)
    end
  end

  def update(conn, %{"id" => slug, "tag" => tag_params}) do
    case Tags.update_tag(conn.assigns.current_user, slug, tag_params) do
      {:ok, tag} ->
        conn
        |> put_flash(:info, "Tag successfully updated.")
        |> redirect(to: ~p"/tags/#{tag}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", tag: changeset.data, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  def delete(conn, params) do
    with {:ok, _tag} <- Tags.delete_tag(conn.assigns.current_user, params["id"]) do
      conn
      |> put_flash(:info, "Tag queued for deletion.")
      |> redirect(to: "/")
    end
  end
end
