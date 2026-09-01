defmodule PhilomenaWeb.TagChangeViewTest do
  use PhilomenaWeb.ConnCase, async: true

  alias Philomena.Users.User
  alias PhilomenaWeb.TagChangeView

  defp viewer_conn(conn, user), do: Plug.Conn.assign(conn, :current_user, user)

  describe "reverts_tag_changes?/1" do
    test "is unavailable to anonymous and regular viewers", %{conn: conn} do
      refute TagChangeView.reverts_tag_changes?(viewer_conn(conn, nil))
      refute TagChangeView.reverts_tag_changes?(viewer_conn(conn, %User{role: "user"}))
    end

    test "is available to moderators and admins", %{conn: conn} do
      assert TagChangeView.reverts_tag_changes?(viewer_conn(conn, %User{role: "moderator"}))
      assert TagChangeView.reverts_tag_changes?(viewer_conn(conn, %User{role: "admin"}))
    end
  end
end
