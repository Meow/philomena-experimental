defmodule PhilomenaWeb.Admin.Advert.ImageController do
  use PhilomenaWeb, :controller

  alias Philomena.Adverts

  action_fallback PhilomenaWeb.FallbackController

  def edit(conn, %{"advert_id" => id}) do
    with {:ok, {advert, changeset}} <- Adverts.load_advert_for_edit(conn.assigns.current_user, id) do
      render(conn, "edit.html", title: "Editing Advert", advert: advert, changeset: changeset)
    end
  end

  def update(conn, %{"advert_id" => id, "advert" => advert_params}) do
    case Adverts.update_advert_image(conn.assigns.current_user, id, advert_params) do
      {:ok, _advert} ->
        conn
        |> put_flash(:info, "Advert was successfully updated.")
        |> redirect(to: ~p"/admin/adverts")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, "edit.html", advert: changeset.data, changeset: changeset)

      {:error, _} = error ->
        error
    end
  end
end
