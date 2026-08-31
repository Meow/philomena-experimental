defmodule PhilomenaWeb.Filter.ClearRecentController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  plug PhilomenaWeb.RequireUserPlug

  def delete(conn, _params) do
    {:ok, _user} = Users.delete_recent_filters(conn.assigns.actor)

    conn
    |> put_flash(:info, "Cleared recent filters.")
    |> redirect(to: ~p"/filters")
  end
end
