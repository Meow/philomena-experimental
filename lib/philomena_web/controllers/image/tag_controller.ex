defmodule PhilomenaWeb.Image.TagController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias Plug.Conn

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.LimitPlug,
       [time: 5, error: "You may only update metadata once every 5 seconds."]
       when action in [:update]

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug
  plug PhilomenaWeb.UserAttributionPlug

  def update(conn, %{"image" => image_params} = params) do
    case Images.update_tags(conn.assigns.actor, params["image_id"], image_params) do
      {:ok,
       %{
         image: image,
         added: added_tags,
         removed: removed_tags,
         tag_change_count: tag_change_count,
         tag_change_tag_count: tag_change_tag_count
       }} ->
        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:tag_update",
          %{
            image_id: image.id,
            added: Enum.map(added_tags, & &1.name),
            removed: Enum.map(removed_tags, & &1.name)
          }
        )

        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:update",
          PhilomenaWeb.Api.Json.ImageView.render("show.json", %{image: image, interactions: []})
        )

        changeset = Images.change_image(image)

        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_tags.html",
          layout: false,
          tag_change_count: tag_change_count,
          tag_change_tag_count: tag_change_tag_count,
          image: image,
          changeset: changeset
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_view(PhilomenaWeb.ImageView)
        |> render("_tags.html",
          layout: false,
          tag_change_count: 0,
          tag_change_tag_count: 0,
          image: changeset.data,
          changeset: changeset
        )

      {:error, :rate_limited} ->
        error_response(conn, "Too many tags changed. Change fewer tags or try again later.")

      {:error, :update_failed} ->
        error_response(conn, "Failed to update tags!")

      {:error, _} = error ->
        error
    end
  end

  # Matches the behavior of PhilomenaWeb.LimitPlug: AJAX requests get an
  # empty 300 response (ujs.ts reloads the page so the flash renders),
  # everything else is redirected back to the referrer.
  defp error_response(conn, message) do
    conn = put_flash(conn, :error, message)

    if conn.assigns.ajax? do
      conn
      |> Conn.send_resp(:multiple_choices, "")
      |> Conn.halt()
    else
      conn
      |> redirect(external: conn.assigns.referrer)
      |> Conn.halt()
    end
  end
end
