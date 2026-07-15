defmodule PhilomenaWeb.FingerprintProfile.SourceChangeController do
  use PhilomenaWeb, :controller

  alias Philomena.SourceChanges

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, %{"fingerprint_profile_id" => fingerprint} = params) do
    with {:ok, source_changes} <-
           SourceChanges.fingerprint_source_changes(
             conn.assigns.actor,
             fingerprint,
             params,
             conn.assigns.scrivener
           ) do
      render(conn, "index.html",
        title: "Source Changes for Fingerprint `#{fingerprint}'",
        fingerprint: fingerprint,
        source_changes: source_changes
      )
    end
  end
end
