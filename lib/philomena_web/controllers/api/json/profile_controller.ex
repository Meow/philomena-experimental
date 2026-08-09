defmodule PhilomenaWeb.Api.Json.ProfileController do
  use PhilomenaWeb, :controller

  alias Philomena.Users
  import PhilomenaWeb.Api.Json.NotFound

  def show(conn, %{"id" => id}) do
    case Users.load_profile_by_id(conn.assigns.actor, id) do
      {:ok, user} ->
        render(conn, "show.json", user: user)

      {:error, :not_found} ->
        not_found(conn)
    end
  end
end
