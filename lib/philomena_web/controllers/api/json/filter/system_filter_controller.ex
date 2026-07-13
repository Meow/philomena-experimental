defmodule PhilomenaWeb.Api.Json.Filter.SystemFilterController do
  use PhilomenaWeb, :controller

  alias Philomena.Filters

  def index(conn, _params) do
    system_filters = Filters.system_filters(conn.assigns.scrivener)

    conn
    |> put_view(PhilomenaWeb.Api.Json.FilterView)
    |> render("index.json", filters: system_filters, total: system_filters.total_entries)
  end
end
