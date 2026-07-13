defmodule PhilomenaWeb.Api.Rss.WatchedController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  def index(conn, _params) do
    scope = PhilomenaWeb.ImageScope.search_scope(conn)
    images = Images.api_watched_images(scope)

    # NB: this is RSS, but using the RSS format causes Phoenix not to
    # escape HTML
    conn
    |> put_resp_header("content-type", "application/rss+xml")
    |> render("index.html", layout: false, images: images)
  end
end
