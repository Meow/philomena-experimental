defmodule PhilomenaWeb.Channel.ReadController do
  use PhilomenaWeb, :controller

  alias Philomena.Channels

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, params) do
    with {:ok, _channel} <-
           Channels.clear_notification(conn.assigns.current_user, params["channel_id"]) do
      send_resp(conn, :ok, "")
    end
  end
end
