defmodule PhilomenaWeb.Api.Json.FilterController do
  use PhilomenaWeb, :controller

  alias Philomena.Filters
  import PhilomenaWeb.Api.Json.NotFound

  def show(conn, %{"id" => id}) do
    case Filters.api_show_filter(conn.assigns.current_user, id) do
      {:ok, filter} ->
        render(conn, "show.json", filter: filter)

      {:error, :not_found} ->
        not_found(conn)
    end
  end
end
