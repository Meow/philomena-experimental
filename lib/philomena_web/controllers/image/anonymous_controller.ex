defmodule PhilomenaWeb.Image.AnonymousController do
  use PhilomenaWeb, :controller

  alias Philomena.Images

  action_fallback PhilomenaWeb.FallbackController

  def create(conn, %{"image_id" => image_id}) do
    with {:ok, _anonymous} <-
           Images.update_anonymous(conn.assigns.actor, image_id, %{anonymous: true}) do
      conn
      |> put_flash(:info, "Successfully updated anonymity.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end

  def delete(conn, %{"image_id" => image_id}) do
    with {:ok, _anonymous} <-
           Images.update_anonymous(conn.assigns.actor, image_id, %{anonymous: false}) do
      conn
      |> put_flash(:info, "Successfully updated anonymity.")
      |> redirect(to: ~p"/images/#{image_id}")
    end
  end
end
