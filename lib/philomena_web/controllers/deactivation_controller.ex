defmodule PhilomenaWeb.DeactivationController do
  use PhilomenaWeb, :controller
  alias PhilomenaWeb.UserAuth
  alias Philomena.Users

  def show(conn, _params) do
    render(conn, "index.html", title: "Deactivate Account")
  end

  def delete(conn, _params) do
    with {:ok, _user} <-
           Users.deactivate_account(conn.assigns.actor, &url(~p"/reactivations/#{&1}")) do
      UserAuth.log_out_user(conn)
    end
  end
end
