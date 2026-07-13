defmodule PhilomenaWeb.Api.Json.CommentController do
  use PhilomenaWeb, :controller

  alias Philomena.Comments
  import PhilomenaWeb.Api.Json.NotFound

  def show(conn, %{"id" => id}) do
    case Comments.api_show_comment(id) do
      {:ok, comment} ->
        render(conn, "show.json", comment: comment)

      {:error, :not_found} ->
        not_found(conn)

      {:error, :hidden_image} ->
        conn
        |> put_status(:forbidden)
        |> text("")
    end
  end
end
