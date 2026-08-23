defmodule PhilomenaWeb.FingerprintProfile.TagChange.RevertController do
  use PhilomenaWeb, :controller

  alias Philomena.TagChanges

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"fingerprint_profile_id" => fingerprint}) do
    case TagChanges.full_revert_fingerprint_tag_changes(conn.assigns.actor, fingerprint) do
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
