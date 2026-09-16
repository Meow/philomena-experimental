defmodule PhilomenaWeb.ImageViewTest do
  use PhilomenaWeb.ConnCase, async: true

  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

  alias Philomena.Repo
  alias PhilomenaWeb.ImageView

  describe "hidden-image disclosure" do
    setup _context do
      image =
        image_fixture(
          hidden_from_users: true,
          hidden_image_key: "image-secret",
          image_width: 1000,
          image_height: 1000
        )

      {:ok, image: Repo.preload(image, tags: :aliases)}
    end

    test "render_intent omits the hidden thumbnail path for regular viewers", %{
      conn: conn,
      image: image
    } do
      {:image, url, _alt} = ImageView.render_intent(viewer_conn(conn, nil), image, :thumb)

      assert url =~ "/#{image.id}/thumb.png"
      refute url =~ image.hidden_image_key
    end

    test "render_intent includes the hidden thumbnail path for moderators", %{
      conn: conn,
      image: image
    } do
      moderator_conn = viewer_conn(conn, moderator_user_fixture())
      {:image, url, _alt} = ImageView.render_intent(moderator_conn, image, :thumb)

      assert url =~ "#{image.id}-#{image.hidden_image_key}/thumb.png"
    end

    test "image_container_data redacts hidden URIs from regular viewers", %{
      conn: conn,
      image: image
    } do
      data = ImageView.image_container_data(viewer_conn(conn, nil), image, :full)

      refute data[:uris] =~ image.hidden_image_key
    end

    test "image_container_data includes hidden URIs for moderators", %{
      conn: conn,
      image: image
    } do
      data =
        ImageView.image_container_data(viewer_conn(conn, moderator_user_fixture()), image, :full)

      assert data[:uris] =~ image.hidden_image_key
    end
  end

  describe "frontend media supplements" do
    test "serializes tagged supplements", %{conn: conn} do
      for {format, mime} <- [{"png", "image/png"}, {"gif", "image/gif"}, {"webm", "video/webm"}] do
        image = image_fixture(image_format: format, image_mime_type: mime)
        image = Repo.preload(image, tags: :aliases)
        media = Philomena.Images.Display.Media.render(image, false)
        data = ImageView.image_container_data(viewer_conn(conn, nil), image, :thumb)

        assert JSON.decode!(data[:uris]) ==
                 JSON.decode!(JSON.encode!(ImageView.display_thumbnail_uris(media)))

        assert JSON.decode!(data[:supplements]) ==
                 JSON.decode!(JSON.encode!(ImageView.display_supplements(media)))

        assert JSON.decode!(data[:supplements])["type"] ==
                 if(format == "png", do: "none", else: format)

        assert Map.keys(JSON.decode!(data[:uris])) |> Enum.sort() ==
                 ~w(full large medium small tall thumb thumb_small thumb_tiny)
      end
    end

    test "unavailable supplements serialize only their status", %{conn: conn} do
      image =
        image_fixture(
          image_format: "webm",
          image_mime_type: "video/webm",
          hidden_from_users: true
        )

      image = Repo.preload(image, tags: :aliases)
      data = ImageView.image_container_data(viewer_conn(conn, nil), image, :thumb)
      assert JSON.decode!(data[:supplements]) == %{"type" => "not_available"}
    end
  end

  describe "hides_images?/1" do
    test "is false for anonymous and regular viewers", %{conn: conn} do
      assert ImageView.hides_images?(viewer_conn(conn, nil)) == false
      assert ImageView.hides_images?(viewer_conn(conn, confirmed_user_fixture())) == false
    end

    test "is true for moderators", %{conn: conn} do
      assert ImageView.hides_images?(viewer_conn(conn, moderator_user_fixture())) == true
    end
  end
end
