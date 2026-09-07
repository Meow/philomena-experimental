defmodule PhilomenaWeb.Image.ScratchpadController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, %{"image_id" => image_id}) do
    with {:ok, changeset} <- Images.edit_image_scratchpad(conn.assigns.actor, image_id) do
      render(conn, "edit.html",
        title: "Editing Moderation Notes",
        changeset: changeset,
        image_id: image_id
      )
    end
  end

  def update(conn, %{"image_id" => image_id} = params) do
    with {:ok, _scratchpad} <-
           Images.update_image_scratchpad(conn.assigns.actor, image_id, params["scratchpad"]) do
      conn
      |> put_flash(:info, "Successfully updated moderation notes.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
