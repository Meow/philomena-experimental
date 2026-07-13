defmodule PhilomenaWeb.Api.Json.Search.GalleryController do
  use PhilomenaWeb, :controller

  alias Philomena.Galleries

  def index(conn, params) do
    user = conn.assigns.current_user

    case Galleries.search_galleries(user, params["q"], conn.assigns.pagination) do
      {:ok, galleries} ->
        conn
        |> put_view(PhilomenaWeb.Api.Json.GalleryView)
        |> render("index.json", galleries: galleries, total: galleries.total_entries)

      {:error, msg} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: msg})
    end
  end
end
