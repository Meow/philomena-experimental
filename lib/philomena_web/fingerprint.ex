defmodule PhilomenaWeb.Fingerprint do
  import Plug.Conn

  alias Philomena.UserFingerprints

  @type t :: String.t()
  @name "_ses"

  @doc """
  Assign the current fingerprint to the conn.
  """
  @spec fetch_fingerprint(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def fetch_fingerprint(conn, _opts) do
    conn =
      conn
      |> fetch_session()
      |> fetch_cookies()

    # Try to get the fingerprint from the session, then from the cookie.
    fingerprint = upgrade(get_session(conn, @name), conn.cookies[@name])

    # If the fingerprint is valid, persist to session.
    if UserFingerprints.valid_format?(fingerprint) do
      conn
      |> put_session(@name, fingerprint)
      |> assign(:fingerprint, fingerprint)
    else
      assign(conn, :fingerprint, nil)
    end
  end

  defp upgrade(<<"c", _::binary>> = session_value, <<"d", _::binary>> = cookie_value) do
    if UserFingerprints.valid_format?(cookie_value) do
      # When both fingerprint values are valid and the session value
      # is an old version, use the cookie value.
      cookie_value
    else
      # Use the session value.
      session_value
    end
  end

  defp upgrade(session_value, cookie_value) do
    # Prefer the session value, using the cookie value if it is unavailable.
    session_value || cookie_value
  end
end
