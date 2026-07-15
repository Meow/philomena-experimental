defmodule PhilomenaWeb.Api.Json.Filter.UserFilterController do
  use PhilomenaWeb, :controller

  alias Philomena.Filters

  def index(conn, _params) do
    case conn.assigns.current_user do
      nil ->
        conn
        |> put_status(:forbidden)
        |> text("")

      _user ->
        user_filters = Filters.user_filters(conn.assigns.actor, conn.assigns.scrivener)

        conn
        |> put_view(PhilomenaWeb.Api.Json.FilterView)
        |> render("index.json", filters: user_filters, total: user_filters.total_entries)
    end
  end
end
