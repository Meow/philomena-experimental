defmodule PhilomenaWeb.Image.LockedTagsControllerTest do
  use PhilomenaWeb.ConnCase, async: true

  import Philomena.ImagesFixtures
  import Philomena.TagsFixtures

  alias Philomena.Repo

  defp locked_tag_names(image) do
    image
    |> Repo.preload(:locked_tags, force: true)
    |> Map.fetch!(:locked_tags)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  describe "GET /images/:image_id/locked_tags/edit" do
    test "redirects anonymous users to login", %{conn: conn} do
      image = image_fixture()

      conn = get(conn, ~p"/images/#{image}/locked_tags/edit")

      assert redirected_to(conn) == ~p"/sessions/new"
    end

    test "rejects a regular user", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      image = image_fixture()

      conn = get(conn, ~p"/images/#{image}/locked_tags/edit")

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You can't access that page."
    end

    test "renders the lock-tags form for a moderator", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})
      image = image_fixture()

      conn = get(conn, ~p"/images/#{image}/locked_tags/edit")
      response = html_response(conn, 200)

      assert response =~ "Locking image tags - Derpibooru"
      assert response =~ "Editing locked tags on image ##{image.id}"
    end

    test "renders the lock-tags form for an admin", %{conn: conn} do
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})
      image = image_fixture()

      conn = get(conn, ~p"/images/#{image}/locked_tags/edit")

      assert html_response(conn, 200) =~ "Editing locked tags on image ##{image.id}"
    end

    test "for an unknown image_id redirects with the not-found flash", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})

      conn = get(conn, ~p"/images/999999999/locked_tags/edit")

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

      conn = get(conn, ~p"/images/not-a-number/locked_tags/edit")

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Couldn't find what you were looking for!"
    end
  end

  describe "PATCH/PUT /images/:image_id/locked_tags" do
    test "redirects anonymous users to login", %{conn: conn} do
      image = image_fixture()

      conn =
        put(conn, ~p"/images/#{image}/locked_tags", %{"locked_tags" => %{"tag_input" => "safe"}})

      assert redirected_to(conn) == ~p"/sessions/new"
      assert locked_tag_names(image) == []
    end

    test "rejects a regular user", %{conn: conn} do
      %{conn: conn} = register_and_log_in_user(%{conn: conn})
      image = image_fixture()

      conn =
        put(conn, ~p"/images/#{image}/locked_tags", %{"locked_tags" => %{"tag_input" => "safe"}})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You can't access that page."
      assert locked_tag_names(image) == []
    end

    test "as a moderator updates the locked tag list", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})
      image = image_fixture()
      tag_fixture(name: "solo")

      conn =
        put(conn, ~p"/images/#{image}/locked_tags", %{
          "locked_tags" => %{"tag_input" => "safe, solo"}
        })

      assert redirected_to(conn) == ~p"/images/#{image}"

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Successfully updated list of locked tags."

      assert locked_tag_names(image) == ["safe", "solo"]
    end

    test "as an admin updates the locked tag list", %{conn: conn} do
      %{conn: conn} = register_and_log_in_admin(%{conn: conn})
      image = image_fixture()
      tag_fixture(name: "solo")

      conn =
        put(conn, ~p"/images/#{image}/locked_tags", %{"locked_tags" => %{"tag_input" => "solo"}})

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Successfully updated list of locked tags."

      assert locked_tag_names(image) == ["solo"]
    end

    # NOTE: an empty tag_input clears the locked tag list; this is a success,
    # not a validation error.
    test "an empty tag_input clears the locked tag list", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})
      image = image_fixture()
      tag_fixture(name: "solo")

      # Lock some tags first.
      put(conn, ~p"/images/#{image}/locked_tags", %{
        "locked_tags" => %{"tag_input" => "safe, solo"}
      })

      assert locked_tag_names(image) == ["safe", "solo"]

      conn =
        put(conn, ~p"/images/#{image}/locked_tags", %{"locked_tags" => %{"tag_input" => ""}})

      assert Phoenix.Flash.get(conn.assigns.flash, :info) ==
               "Successfully updated list of locked tags."

      assert locked_tag_names(image) == []
    end

    test "for an unknown image_id redirects with the not-found flash", %{conn: conn} do
      %{conn: conn} = register_and_log_in_moderator(%{conn: conn})

      conn =
        put(conn, ~p"/images/999999999/locked_tags", %{
          "locked_tags" => %{"tag_input" => "safe"}
        })

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

      conn =
        put(conn, ~p"/images/not-a-number/locked_tags", %{
          "locked_tags" => %{"tag_input" => "safe"}
        })

      assert redirected_to(conn) == "/"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Couldn't find what you were looking for!"
    end
  end
end
