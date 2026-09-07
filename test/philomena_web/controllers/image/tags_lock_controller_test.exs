defmodule PhilomenaWeb.Image.TagsLockControllerTest do
  use PhilomenaWeb.ConnCase, async: true

  import Philomena.ImagesFixtures

  alias Philomena.Repo

  # NOTE: "locking tags" is stored inverted on the `tag_editing_allowed`
  # column; there is no `tags_locked` field.
  defp tags_editable?(image), do: Repo.reload!(image).tag_editing_allowed

  describe "POST /images/:image_id/tags_lock" do
    test "redirects anonymous users to login", %{conn: conn} do
      image = image_fixture()

      conn = post(conn, ~p"/images/#{image}/tags_lock")

      assert redirected_to(conn) == ~p"/sessions/new"
      assert tags_editable?(image)
    end

    test "rejects a regular user", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      image = image_fixture()

      conn = post(conn, ~p"/images/#{image}/tags_lock")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You can't access that page."
      assert tags_editable?(image)
    end

    test "as a moderator locks tags", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})
      image = image_fixture()

      conn = post(conn, ~p"/images/#{image}/tags_lock")

      assert redirected_to(conn) == ~p"/images/#{image}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Successfully locked tags."
      refute tags_editable?(image)
    end

    test "as an admin locks tags", %{conn: conn} do
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})
      image = image_fixture()

      conn = post(conn, ~p"/images/#{image}/tags_lock")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Successfully locked tags."
      refute tags_editable?(image)
    end

    test "for an unknown image_id redirects with the not-found flash", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})

      conn = post(conn, ~p"/images/999999999/tags_lock")

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Couldn't find what you were looking for!"
    end

    # NOTE: a non-integer image_id short-circuits to NotFoundPlug via the central
    # IntegerId guard before authorization runs, so the flash is the not-found
    # message rather than the "You can't access that page." an unknown integer
    # id gets.
    test "for a non-integer image_id redirects with the not-found flash", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})

      conn = post(conn, ~p"/images/not-a-number/tags_lock")

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Couldn't find what you were looking for!"
    end
  end

  describe "DELETE /images/:image_id/tags_lock" do
    test "redirects anonymous users to login", %{conn: conn} do
      image = image_fixture(tag_editing_allowed: false)

      conn = delete(conn, ~p"/images/#{image}/tags_lock")

      assert redirected_to(conn) == ~p"/sessions/new"
      refute tags_editable?(image)
    end

    test "rejects a regular user", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      image = image_fixture(tag_editing_allowed: false)

      conn = delete(conn, ~p"/images/#{image}/tags_lock")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You can't access that page."
      refute tags_editable?(image)
    end

    test "as a moderator unlocks tags", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})
      image = image_fixture(tag_editing_allowed: false)

      conn = delete(conn, ~p"/images/#{image}/tags_lock")

      assert redirected_to(conn) == ~p"/images/#{image}"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Successfully unlocked tags."
      assert tags_editable?(image)
    end

    test "as an admin unlocks tags", %{conn: conn} do
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})
      image = image_fixture(tag_editing_allowed: false)

      conn = delete(conn, ~p"/images/#{image}/tags_lock")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Successfully unlocked tags."
      assert tags_editable?(image)
    end

    test "for an unknown image_id redirects with the not-found flash", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})

      conn = delete(conn, ~p"/images/999999999/tags_lock")

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Couldn't find what you were looking for!"
    end

    # NOTE: a non-integer image_id short-circuits to NotFoundPlug via the central
    # IntegerId guard before authorization runs, so the flash is the not-found
    # message rather than the "You can't access that page." an unknown integer
    # id gets.
    test "for a non-integer image_id redirects with the not-found flash", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})

      conn = delete(conn, ~p"/images/not-a-number/tags_lock")

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Couldn't find what you were looking for!"
    end
  end
end
