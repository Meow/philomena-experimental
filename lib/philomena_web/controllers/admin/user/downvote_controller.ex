defmodule PhilomenaWeb.Admin.User.DownvoteController do
  use PhilomenaWeb, :controller

  alias Philomena.Users

  action_fallback PhilomenaWeb.FallbackController

  def delete(conn, %{"user_id" => slug}) do
    with {:ok, user} <- Users.admin_wipe_downvotes(conn.assigns.current_user, slug) do
      conn
      |> put_flash(:info, "Downvote wipe started.")
      |> redirect(to: ~p"/profiles/#{user}")
    end
  end
end
