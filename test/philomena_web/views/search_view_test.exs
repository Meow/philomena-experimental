defmodule PhilomenaWeb.SearchViewTest do
  use PhilomenaWeb.ConnCase, async: true

  alias Philomena.Users.User
  alias PhilomenaWeb.SearchView

  defp viewer_conn(conn, user), do: Plug.Conn.assign(conn, :current_user, user)

  describe "hides_images?/1" do
    test "is unavailable to anonymous and regular viewers", %{conn: conn} do
      refute SearchView.hides_images?(viewer_conn(conn, nil))
      refute SearchView.hides_images?(viewer_conn(conn, %User{role: "user"}))
    end

    test "is available to moderators and admins", %{conn: conn} do
      assert SearchView.hides_images?(viewer_conn(conn, %User{role: "moderator"}))
      assert SearchView.hides_images?(viewer_conn(conn, %User{role: "admin"}))
    end
  end
end
