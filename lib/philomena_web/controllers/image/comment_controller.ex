defmodule PhilomenaWeb.Image.CommentController do
  use PhilomenaWeb, :controller

  alias PhilomenaWeb.MarkdownRenderer
  alias PhilomenaWeb.RateLimitedResponse
  alias Philomena.Comments

  action_fallback PhilomenaWeb.FallbackController

  plug :load_commentable_image when action in [:index, :show, :create, :edit, :update]

  plug PhilomenaWeb.FilterForcedUsersPlug when action in [:create, :edit, :update]

  def index(conn, %{"comment_id" => comment_id}) do
    page =
      Comments.find_comment_page(
        conn.assigns.actor,
        conn.assigns.image,
        comment_id,
        conn.assigns.comment_scrivener
      )

    redirect(conn, to: ~p"/images/#{conn.assigns.image}/comments?#{[page: page]}")
  end

  def index(conn, _params) do
    comments =
      Comments.paginate_image_comments(
        conn.assigns.actor,
        conn.assigns.image,
        conn.assigns.comment_scrivener
      )

    rendered = MarkdownRenderer.render_collection(comments.entries, conn)

    comments = %{comments | entries: Enum.zip(comments.entries, rendered)}

    render(conn, "index.html", layout: false, image: conn.assigns.image, comments: comments)
  end

  def show(conn, %{"id" => comment_id}) do
    with {:ok, comment} <- Comments.load_comment_for_show(conn.assigns.image, comment_id) do
      rendered = MarkdownRenderer.render_one(comment, conn)

      render(conn, "show.html",
        layout: false,
        image: conn.assigns.image,
        comment: comment,
        body: rendered
      )
    end
  end

  def create(conn, %{"comment" => comment_params}) do
    case Comments.create_comment(conn.assigns.actor, conn.assigns.image, comment_params) do
      {:ok, comment} ->
        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "comment:create",
          PhilomenaWeb.Api.Json.CommentView.render("show.json", %{comment: comment})
        )

        index(conn, %{"comment_id" => comment.id})

      {:error, :creation_failed} ->
        conn
        |> put_flash(:error, "There was an error posting your comment")
        |> redirect(to: ~p"/images/#{conn.assigns.image}")

      {:error, :rate_limited} ->
        RateLimitedResponse.call(conn, "You may only create a comment once every 15 seconds.")

      {:error, _} = error ->
        error
    end
  end

  def edit(conn, %{"id" => comment_id}) do
    with {:ok, {comment, changeset}} <-
           Comments.load_comment_for_edit(conn.assigns.actor, conn.assigns.image, comment_id) do
      render(conn, "edit.html",
        title: "Editing Comment",
        comment: comment,
        changeset: changeset
      )
    end
  end

  def update(conn, %{"id" => comment_id, "comment" => comment_params}) do
    case Comments.update_comment(
           conn.assigns.actor,
           conn.assigns.image,
           comment_id,
           comment_params
         ) do
      {:ok, comment} ->
        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "comment:update",
          PhilomenaWeb.Api.Json.CommentView.render("show.json", %{comment: comment})
        )

        conn
        |> put_flash(:info, "Comment updated successfully.")
        |> redirect(to: ~p"/images/#{conn.assigns.image}" <> "#comment_#{comment.id}")

      {:error, {comment, changeset}} ->
        render(conn, "edit.html", comment: comment, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end

  # Loads and authorizes the commented-on image into `:image` for the action's
  # ability, so the forced-filter check and the comment pages have it available.
  # A load or authorization failure renders the global error and halts.
  defp load_commentable_image(conn, _opts) do
    case Comments.load_commentable_image(
           conn.assigns.actor,
           conn.params["image_id"],
           action_name(conn)
         ) do
      {:ok, image} ->
        assign(conn, :image, image)

      error ->
        conn
        |> PhilomenaWeb.FallbackController.call(error)
        |> halt()
    end
  end
end
