defmodule PhilomenaWeb.ForumListPlug do
  alias Plug.Conn

  alias Philomena.Forums

  def init(opts), do: opts

  def call(conn, _opts) do
    forums = Forums.load_forum_index(conn.assigns.actor).forums

    conn
    |> Conn.assign(:forums, forums)
  end
end
