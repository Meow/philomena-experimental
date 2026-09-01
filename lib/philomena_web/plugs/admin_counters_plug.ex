defmodule PhilomenaWeb.AdminCountersPlug do
  @moduledoc """
  This plug stores the counts used by the admin bar.

  ## Example

      plug PhilomenaWeb.AdminCountersPlug

  """

  alias Philomena.Administration

  import Plug.Conn, only: [assign: 3]

  @doc false
  @spec init(any()) :: any()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t()) :: Plug.Conn.t()
  def call(conn), do: call(conn, nil)

  @doc false
  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, _opts) do
    navigation = Administration.show_navigation(conn.assigns.actor)

    assign(conn, :admin_navigation, navigation)
  end
end
