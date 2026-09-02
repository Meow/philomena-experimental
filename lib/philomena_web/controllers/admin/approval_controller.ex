defmodule PhilomenaWeb.Admin.ApprovalController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def index(conn, _params) do
    with {:ok, images} <-
           Images.list_approval_queue(conn.assigns.actor, conn.assigns.scrivener) do
      policies = Map.new(images.entries, &{&1.id, Images.image_policy(conn.assigns.actor, &1)})
      media = Map.new(images.entries, &{&1.id, Images.image_entry(conn.assigns.actor, &1).media})

      attributions =
        Map.new(images.entries, &{&1.id, Images.image_attribution(conn.assigns.actor, &1)})

      render(conn, "index.html",
        title: "Admin - Approval Queue",
        images: images,
        image_policies: policies,
        image_media: media,
        image_attributions: attributions
      )
    end
  end
end
