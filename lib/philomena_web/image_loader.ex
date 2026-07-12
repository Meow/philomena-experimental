defmodule PhilomenaWeb.ImageLoader do
  @moduledoc """
  Conn-based facade over `Philomena.Images.Search` for controllers that have
  not yet moved to building a search scope themselves.
  """

  alias Philomena.Images.Search, as: ImageSearch
  alias PhilomenaWeb.ImageScope
  alias PhilomenaWeb.TagInfoRenderer

  def default_query(conn, options \\ []) do
    {definition, tags} = ImageSearch.default_query(ImageScope.search_scope(conn), options)

    {definition, TagInfoRenderer.render_tag_info(tags, conn)}
  end

  def search_string(conn, search_string, options \\ []) do
    case ImageSearch.search_string(ImageScope.search_scope(conn), search_string, options) do
      {:ok, {definition, tags}} ->
        {:ok, {definition, TagInfoRenderer.render_tag_info(tags, conn)}}

      error ->
        error
    end
  end

  def query(conn, body, options \\ []) do
    {definition, tags} = ImageSearch.query(ImageScope.search_scope(conn), body, options)

    {definition, TagInfoRenderer.render_tag_info(tags, conn)}
  end
end
