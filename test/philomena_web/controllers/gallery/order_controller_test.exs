defmodule PhilomenaWeb.Gallery.OrderControllerTest do
  use PhilomenaWeb.ConnCase, async: true

  import Philomena.GalleriesFixtures
  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

  test "anonymous requests redirect to the login page", %{conn: conn} do
    conn = patch(conn, ~p"/galleries/1/order", %{"image_ids" => []})

    assert redirected_to(conn) == ~p"/sessions/new"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "You must log in to access this page."
  end

  test "PATCH responds 200 as the gallery's owner", %{conn: conn} do
    # the reorder itself is only enqueued (dead Exq job in test), so the 200
    # is the whole observable contract
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    gallery = gallery_fixture(user)
    [image_a, image_b] = [image_fixture(), image_fixture()]
    gallery_image_fixture(gallery, image_a)
    gallery_image_fixture(gallery, image_b)

    conn =
      patch(conn, ~p"/galleries/#{gallery}/order", %{"image_ids" => [image_b.id, image_a.id]})

    assert json_response(conn, 200) == %{}
  end

  test "PUT responds 200 as the gallery's owner", %{conn: conn} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    gallery = gallery_fixture(user)

    conn = put(conn, ~p"/galleries/#{gallery}/order", %{"image_ids" => []})

    assert json_response(conn, 200) == %{}
  end

  test "responds 400 when image_ids is not the gallery's exact membership", %{conn: conn} do
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    gallery = gallery_fixture(user)
    image = image_fixture()
    gallery_image_fixture(gallery, image)

    conn = patch(conn, ~p"/galleries/#{gallery}/order", %{"image_ids" => []})

    assert json_response(conn, 400) == %{
             "error" => "image_ids must exactly match the gallery's images"
           }
  end

  test "crashes when image_ids is missing", %{conn: conn} do
    # update/2 only matches when image_ids is a list
    %{conn: conn, user: user} = register_and_log_in_user(%{conn: conn})
    gallery = gallery_fixture(user)

    assert_raise Phoenix.ActionClauseError, fn ->
      patch(conn, ~p"/galleries/#{gallery}/order", %{})
    end
  end

  test "redirects other users with the authorization flash", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})
    gallery = gallery_fixture(confirmed_user_fixture())

    conn = patch(conn, ~p"/galleries/#{gallery}/order", %{"image_ids" => []})

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "You can't access that page."
  end

  test "redirects banned users with the ban flash", %{conn: conn} do
    %{conn: conn} = register_and_log_in_banned_user(%{conn: conn})

    conn = patch(conn, ~p"/galleries/1/order", %{"image_ids" => []})

    assert redirected_to(conn) == "/"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "You are currently banned"
  end
end
