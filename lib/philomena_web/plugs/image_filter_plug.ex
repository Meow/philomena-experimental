defmodule PhilomenaWeb.ImageFilterPlug do
  import Plug.Conn
  alias Philomena.Filters

  # No options
  def init([]), do: false

  # Assign current filter
  def call(conn, _opts) do
    case Filters.compile_image_filter(
           conn.assigns.actor,
           conn.assigns[:current_filter],
           conn.assigns[:forced_filter]
         ) do
      {:ok, image_filter} ->
        assign(conn, :image_filter, image_filter)

      {:error, {:invalid_filter, _filter, _field, _reason}} ->
        conn
        |> send_resp(422, "Invalid image filter")
        |> halt()
    end
  end
end
