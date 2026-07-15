defmodule PhilomenaWeb.Image.TagController do
  use PhilomenaWeb, :controller

  alias Philomena.Images
  alias PhilomenaWeb.RateLimitedResponse

  action_fallback PhilomenaWeb.FallbackController

  plug PhilomenaWeb.CaptchaPlug
  plug PhilomenaWeb.CheckCaptchaPlug

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
        RateLimitedResponse.call(
          conn,
          "Too many tags changed. Change fewer tags or try again later."
        )

      {:error, :update_failed} ->
        RateLimitedResponse.call(conn, "Failed to update tags!")

      {:error, _} = error ->
        error
    end
  end
end
