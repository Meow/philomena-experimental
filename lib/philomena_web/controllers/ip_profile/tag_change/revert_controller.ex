defmodule PhilomenaWeb.IpProfile.TagChange.RevertController do
  use PhilomenaWeb, :controller

  alias Philomena.TagChanges

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"ip_profile_id" => ip}) do
    case TagChanges.full_revert_ip_tag_changes(conn.assigns.actor, ip) do
      {:ok, _target} ->
        conn
        |> put_flash(:info, "Reversion of tag changes enqueued.")
        |> redirect(external: conn.assigns.referrer)

      {:error, :unauthorized} = error ->
        error

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Couldn't revert those tag changes!")
        |> redirect(external: conn.assigns.referrer)

      error ->
        error
    end
  end
end
