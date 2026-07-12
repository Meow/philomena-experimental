defmodule PhilomenaWeb.Admin.ArtistLinkController do
  use PhilomenaWeb, :controller

  alias Philomena.ArtistLinks

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, params) do
    with {:ok, artist_links} <-
           ArtistLinks.load_artist_links_index(
             conn.assigns.current_user,
             params,
             conn.assigns.scrivener
           ) do
      render(conn, "index.html", title: "Admin - Artist Links", artist_links: artist_links)
    end
  end
end
