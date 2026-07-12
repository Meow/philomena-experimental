defmodule PhilomenaWeb.Filter.CurrentController do
  use PhilomenaWeb, :controller

  @cookie_opts [max_age: 788_923_800, same_site: "Lax"]

  alias Philomena.Filters

  action_fallback PhilomenaWeb.FallbackController

  def update(conn, params) do
    user = conn.assigns.current_user

    with {:ok, filter} <- Filters.switch_current_filter(user, params["id"]) do
      conn
      |> put_filter_cookie(user, filter)
      |> put_flash(:info, "Switched to filter #{filter.name}")
      |> redirect(external: conn.assigns.referrer)
    end
  end

  defp put_filter_cookie(conn, nil, filter),
    do: put_resp_cookie(conn, "filter_id", Integer.to_string(filter.id), @cookie_opts)

  defp put_filter_cookie(conn, _user, _filter), do: conn
end
