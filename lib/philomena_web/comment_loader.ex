defmodule PhilomenaWeb.CommentLoader do
  @moduledoc """
  Conn-based facade over the comment listing functions in
  `Philomena.Comments`, for controllers that have not yet moved to calling
  them with request data directly.
  """

  alias Philomena.Comments

  def load_comments(conn, image) do
    Comments.paginate_image_comments(
      conn.assigns.current_user,
      image,
      conn.assigns.comment_scrivener
    )
  end

  def find_page(conn, image, comment_id) do
    Comments.find_comment_page(
      conn.assigns.current_user,
      image,
      comment_id,
      conn.assigns.comment_scrivener
    )
  end

  def last_page(conn, image) do
    Comments.last_comment_page(conn.assigns.current_user, image, conn.assigns.comment_scrivener)
  end

  def query(conn, body, options \\ []) do
    Comments.comment_search_definition(
      conn.assigns.current_user,
      conn.assigns.current_filter,
      body,
      pagination: Keyword.get(options, :pagination, conn.assigns.pagination),
      show_hidden: Keyword.get(options, :show_hidden, true)
    )
  end
end
