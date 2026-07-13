defmodule PhilomenaWeb.Api.Json.Search.TagController do
  use PhilomenaWeb, :controller

  alias Philomena.Tags

  def index(conn, params) do
    case Tags.search_tags(params["q"], conn.assigns.pagination) do
      {:ok, tags} ->
        conn
        |> put_view(PhilomenaWeb.Api.Json.TagView)
        |> render("index.json", tags: tags, total: tags.total_entries)

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})
    end
  end
end
