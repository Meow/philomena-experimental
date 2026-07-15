defmodule PhilomenaWeb.Profile.SourceChangeController do
  use PhilomenaWeb, :controller

  alias Philomena.SourceChanges

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, %{"profile_id" => slug} = params) do
    with {:ok, {user, source_changes, image_count}} <-
           SourceChanges.user_source_changes(
             conn.assigns.actor,
             slug,
             params,
             conn.assigns.scrivener
           ) do
      render(conn, "index.html",
        title: "Source Changes for User `#{user.name}'",
        user: user,
        source_changes: source_changes,
        image_count: image_count
      )
    end
  end
end
