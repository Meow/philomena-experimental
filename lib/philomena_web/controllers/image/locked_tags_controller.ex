defmodule PhilomenaWeb.Image.LockedTagsController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, %{"image_id" => image_id}) do
    with {:ok, changeset} <- Images.edit_image_locked_tags(conn.assigns.actor, image_id) do
      render(conn, "show.html",
        title: "Locking image tags",
        image_id: image_id,
        changeset: changeset
      )
    end
  end

  def update(conn, %{"image_id" => image_id} = params) do
    with {:ok, _locked_tags} <-
           Images.update_image_locked_tags(conn.assigns.actor, image_id, params["locked_tags"]) do
      conn
      |> put_flash(:info, "Successfully updated list of locked tags.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
