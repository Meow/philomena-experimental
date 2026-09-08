defmodule PhilomenaWeb.Image.TagController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias PhilomenaWeb.RateLimitedResponse

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug

  def update(conn, %{"image_id" => image_id} = params) do
    case Images.update_image_tags(conn.assigns.actor, image_id, params["tag_input"]) do
      {:ok, %{tags: tags}} ->
        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_tags.html",
          layout: false,
          image_id: image_id,
          tags: tags
        )

      {:error, %{tags: tags}} ->
        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_tags.html",
          layout: false,
          image_id: image_id,
          tags: tags
        )

      {:error, :rate_limited} ->
        RateLimitedResponse.call(
          conn,
          "Too many tags changed. Change fewer tags or try again later."
        )

      error ->
        error
    end
  end
end
