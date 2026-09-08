defmodule PhilomenaWeb.Image.SourceController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias PhilomenaWeb.RateLimitedResponse

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug

  def update(conn, %{"image_id" => image_id} = params) do
    case Images.update_image_sources(conn.assigns.actor, image_id, params["source_input"]) do
      {:ok, %{sources: sources}} ->
        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_source.html",
          layout: false,
          image_id: image_id,
          sources: sources
        )

      {:error, %{sources: sources}} ->
        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_source.html",
          layout: false,
          image_id: image_id,
          sources: sources
        )

      {:error, :rate_limited} ->
        RateLimitedResponse.call(conn, "You may only update metadata once every 5 seconds.")

      error ->
        error
    end
  end
end
