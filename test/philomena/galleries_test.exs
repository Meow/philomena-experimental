defmodule Philomena.GalleriesTest do
  @moduledoc """
  Context-level tests for the actor-first `Philomena.Galleries` functions.

  These pin the authorization matrices on the write paths (ban, missing
  fingerprint, owner vs unrelated user vs admin), the form loaders, the
  add/remove/reorder image operations, the read-mark and subscription
  helpers, and the two search-backed loaders (`load_gallery_page/2` and
  `load_gallery_index/2`).
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.AttributionFixtures
  import Philomena.GalleriesFixtures
  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures
  import Philomena.ReportsFixtures

  alias Philomena.Galleries
  alias Philomena.Galleries.Gallery
  alias Philomena.Galleries.GalleryPage
  alias Philomena.Galleries.Interaction
  alias Philomena.Images.Image
  alias Philomena.Images.Search.Scope
  alias Philomena.Repo
  alias Philomena.Reports.Report
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  # A truthy ban value in the shape production passes; only its presence
  # matters to the write-access and not-banned checks the loaders run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  @pagination %{page_number: 1, page_size: 25}

  setup do
    Search.clear_index!(Gallery)
    Search.clear_index!(Image)
    :ok
  end

  # The compiled filter body for a viewer with no active filter: it excludes
  # nothing.
  defp default_filter do
    %{
      bool: %{
        should: [
          %{terms: %{tag_ids: []}},
          %{bool: %{should: [%{match_none: %{}}, %{match_none: %{}}]}}
        ]
      }
    }
  end

  defp scope(user) do
    %Scope{user: user, filter: default_filter(), params: %{}, pagination: @pagination}
  end

  describe "new_gallery/1" do
    test "an anonymous actor gets the new-gallery changeset" do
      assert {:ok, %Ecto.Changeset{data: %Gallery{}}} = Galleries.new_gallery(actor(nil))
    end

    test "a signed-in actor gets the new-gallery changeset" do
      assert {:ok, %Ecto.Changeset{}} = Galleries.new_gallery(actor(confirmed_user_fixture()))
    end

    test "a banned actor is rejected even while carrying a fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Galleries.new_gallery(actor) == {:error, :ban}
    end

    test "an actor without a fingerprint may not reach the form" do
      assert Galleries.new_gallery(actor(nil, fingerprint: nil)) == {:error, :unauthorized}
    end
  end

  describe "create_gallery/2 with an actor" do
    test "a signed-in actor creates a gallery attributed to the user" do
      user = confirmed_user_fixture()
      thumbnail = image_fixture()

      assert {:ok, %Gallery{} = gallery} =
               Galleries.create_gallery(actor(user), %{
                 "title" => "A brand new gallery",
                 "thumbnail_id" => to_string(thumbnail.id)
               })

      assert gallery.user_id == user.id
      assert gallery.title == "A brand new gallery"
      assert Repo.get(Gallery, gallery.id)
    end

    test "a blank title is a rejected changeset" do
      thumbnail = image_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Galleries.create_gallery(actor(confirmed_user_fixture()), %{
                 "title" => "",
                 "thumbnail_id" => to_string(thumbnail.id)
               })

      refute changeset.valid?
      assert changeset.errors[:title]
    end

    test "a banned actor is rejected" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Galleries.create_gallery(actor, %{"title" => "x"}) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Galleries.create_gallery(actor, %{"title" => "x"}) == {:error, :unauthorized}
    end

    test "the ban wins over a missing fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban, fingerprint: nil)

      assert Galleries.create_gallery(actor, %{"title" => "x"}) == {:error, :ban}
    end
  end

  describe "update_gallery/3" do
    test "the owner updates their gallery" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)

      assert {:ok, %Gallery{}} =
               Galleries.update_gallery(actor(user), "#{gallery.id}", %{"title" => "Renamed"})

      assert Repo.reload!(gallery).title == "Renamed"
    end

    test "an admin updates another user's gallery" do
      gallery = gallery_fixture(confirmed_user_fixture())

      assert {:ok, %Gallery{}} =
               Galleries.update_gallery(actor(admin_user_fixture()), "#{gallery.id}", %{
                 "title" => "Admin renamed"
               })

      assert Repo.reload!(gallery).title == "Admin renamed"
    end

    test "an unrelated user is unauthorized and leaves the row unchanged" do
      gallery = gallery_fixture(confirmed_user_fixture())

      assert Galleries.update_gallery(actor(confirmed_user_fixture()), "#{gallery.id}", %{
               "title" => "Hijacked"
             }) == {:error, :unauthorized}

      assert Repo.reload!(gallery).title == gallery.title
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Galleries.update_gallery(actor, "abc", %{"title" => "x"}) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized" do
      gallery = gallery_fixture(confirmed_user_fixture())
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Galleries.update_gallery(actor, "#{gallery.id}", %{"title" => "x"}) ==
               {:error, :unauthorized}
    end

    test "the ban wins over a missing fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban, fingerprint: nil)

      assert Galleries.update_gallery(actor, "abc", %{"title" => "x"}) == {:error, :ban}
    end

    test "a non-castable id is not-found" do
      assert Galleries.update_gallery(actor(confirmed_user_fixture()), "abc", %{"title" => "x"}) ==
               {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Galleries.update_gallery(actor(confirmed_user_fixture()), "999999999", %{
               "title" => "x"
             }) == {:error, :unauthorized}

      assert Galleries.update_gallery(actor(admin_user_fixture()), "999999999", %{"title" => "x"}) ==
               {:error, :not_found}
    end
  end

  describe "delete_gallery/2" do
    test "the owner deletes their gallery" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)

      assert {:ok, %Gallery{} = deleted} = Galleries.delete_gallery(actor(user), "#{gallery.id}")
      assert deleted.id == gallery.id
      assert Repo.reload(gallery) == nil
    end

    test "an unrelated user is unauthorized and leaves the row" do
      gallery = gallery_fixture(confirmed_user_fixture())

      assert Galleries.delete_gallery(actor(confirmed_user_fixture()), "#{gallery.id}") ==
               {:error, :unauthorized}

      refute Repo.reload(gallery) == nil
    end

    test "a banned actor is rejected even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Galleries.delete_gallery(actor, "abc") == {:error, :ban}
    end

    test "a non-castable id is not-found" do
      assert Galleries.delete_gallery(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Galleries.delete_gallery(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      assert Galleries.delete_gallery(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end
  end

  describe "delete_gallery/3" do
    test "closes the gallery's open reports and nulls the target FK while keeping the row" do
      gallery = gallery_fixture(confirmed_user_fixture())
      report = report_fixture(gallery_id: gallery.id)
      admin = admin_user_fixture()

      assert report.open
      assert report.gallery_id == gallery.id

      assert {:ok, _gallery} = Galleries.delete_gallery(gallery, admin, nil)

      closed = Repo.get!(Report, report.id)
      refute closed.open
      assert closed.state == "closed"
      assert closed.admin_id == admin.id
      # The FK is nilified by the database, orphaning the report as audit trail.
      assert closed.gallery_id == nil
      assert Enum.all?(Report.target_columns(), &is_nil(Map.get(closed, &1)))

      refute Repo.get(Philomena.Galleries.Gallery, gallery.id)
    end
  end

  describe "load_gallery_for_edit/2" do
    test "the owner loads the gallery paired with its edit changeset" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)

      assert {:ok, {%Gallery{} = loaded, %Ecto.Changeset{} = changeset}} =
               Galleries.load_gallery_for_edit(actor(user), "#{gallery.id}")

      assert loaded.id == gallery.id
      assert changeset.data.id == gallery.id
    end

    test "an unrelated user is unauthorized" do
      gallery = gallery_fixture(confirmed_user_fixture())

      assert Galleries.load_gallery_for_edit(actor(confirmed_user_fixture()), "#{gallery.id}") ==
               {:error, :unauthorized}
    end

    test "a banned actor is rejected even while carrying a fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Galleries.load_gallery_for_edit(actor, "abc") == {:error, :ban}
    end

    test "an actor without a fingerprint is rejected before loading" do
      assert Galleries.load_gallery_for_edit(actor(nil, fingerprint: nil), "abc") ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Galleries.load_gallery_for_edit(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end

    test "a well-formed id naming no row is unauthorized for a user, not-found for an admin" do
      assert Galleries.load_gallery_for_edit(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      assert Galleries.load_gallery_for_edit(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end
  end

  describe "add_image_to_gallery/3" do
    test "the owner adds an image at the last position" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)
      image = image_fixture()

      assert {:ok, result} =
               Galleries.add_image_to_gallery(actor(user), "#{gallery.id}", "#{image.id}")

      assert %Gallery{} = result.gallery
      assert %Interaction{} = result.interaction
      assert result.image_count == 1
      assert Repo.reload!(gallery).image_count == 1
    end

    test "an unrelated user is unauthorized" do
      gallery = gallery_fixture(confirmed_user_fixture())
      image = image_fixture()

      assert Galleries.add_image_to_gallery(
               actor(confirmed_user_fixture()),
               "#{gallery.id}",
               "#{image.id}"
             ) == {:error, :unauthorized}
    end

    test "a banned actor is rejected" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Galleries.add_image_to_gallery(actor, "abc", "abc") == {:error, :ban}
    end

    test "adding an image already in the gallery is a Multi failure on the interaction" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)
      image = image_fixture()

      {:ok, _} = Galleries.add_image_to_gallery(actor(user), "#{gallery.id}", "#{image.id}")

      # The (gallery_id, image_id) unique constraint rejects the second insert,
      # surfacing as a Multi failure on the :interaction step.
      assert {:error, :interaction, %Ecto.Changeset{} = changeset, _changes} =
               Galleries.add_image_to_gallery(actor(user), "#{gallery.id}", "#{image.id}")

      refute changeset.valid?
    end
  end

  describe "remove_image_from_gallery/3" do
    test "the owner removes an image in the gallery" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)
      image = image_fixture()

      {:ok, _} = Galleries.add_image_to_gallery(actor(user), "#{gallery.id}", "#{image.id}")

      assert {:ok, result} =
               Galleries.remove_image_from_gallery(actor(user), "#{gallery.id}", "#{image.id}")

      assert result.interaction == 1
      assert result.image_count == 1
      assert Repo.reload!(gallery).image_count == 0
    end

    test "removing an image not in the gallery is an idempotent success" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)
      image = image_fixture()

      assert {:ok, result} =
               Galleries.remove_image_from_gallery(actor(user), "#{gallery.id}", "#{image.id}")

      assert result.interaction == 0
    end

    test "an unrelated user is unauthorized" do
      gallery = gallery_fixture(confirmed_user_fixture())
      image = image_fixture()

      assert Galleries.remove_image_from_gallery(
               actor(confirmed_user_fixture()),
               "#{gallery.id}",
               "#{image.id}"
             ) == {:error, :unauthorized}
    end
  end

  describe "reorder_gallery/3" do
    test "the owner queues a reorder and gets the gallery back" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)

      assert {:ok, %Gallery{} = returned} =
               Galleries.reorder_gallery(actor(user), "#{gallery.id}", [3, 1, 2])

      assert returned.id == gallery.id
    end

    test "an unrelated user is unauthorized" do
      gallery = gallery_fixture(confirmed_user_fixture())

      assert Galleries.reorder_gallery(actor(confirmed_user_fixture()), "#{gallery.id}", [1, 2]) ==
               {:error, :unauthorized}
    end

    test "a banned actor is rejected" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Galleries.reorder_gallery(actor, "abc", [1]) == {:error, :ban}
    end
  end

  describe "mark_gallery_read/2" do
    test "a known gallery is marked read for the user" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(confirmed_user_fixture())

      assert {:ok, %Gallery{} = returned} =
               Galleries.mark_gallery_read(actor(user), "#{gallery.id}")

      assert returned.id == gallery.id
    end

    # No authorization runs here, so an unknown id is not-found for everyone,
    # admins included.
    test "an unknown id is not-found for a user and for an admin" do
      assert Galleries.mark_gallery_read(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :not_found}

      assert Galleries.mark_gallery_read(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end

    test "a non-castable id is not-found" do
      assert Galleries.mark_gallery_read(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end
  end

  describe "subscribe_gallery/2 and unsubscribe_gallery/2" do
    test "subscribing then unsubscribing toggles the subscription" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(confirmed_user_fixture())

      assert {:ok, %Gallery{}} = Galleries.subscribe_gallery(actor(user), "#{gallery.id}")
      assert Galleries.subscribed?(gallery, user)

      assert {:ok, %Gallery{}} = Galleries.unsubscribe_gallery(actor(user), "#{gallery.id}")
      refute Galleries.subscribed?(gallery, user)
    end

    test "unsubscribing when not subscribed is an idempotent success" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(confirmed_user_fixture())

      assert {:ok, %Gallery{}} = Galleries.unsubscribe_gallery(actor(user), "#{gallery.id}")
      refute Galleries.subscribed?(gallery, user)
    end

    test "subscribing to an unknown id is unauthorized for a user" do
      assert Galleries.subscribe_gallery(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Galleries.subscribe_gallery(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end
  end

  describe "load_gallery_page/2" do
    test "the owner's scope gets a gallery page containing the gallery's image" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)
      image = image_fixture()

      {:ok, _} = Galleries.add_image_to_gallery(gallery, image)
      SearchHelpers.reindex_all!(Image)

      assert {:ok, %GalleryPage{} = page} =
               Galleries.load_gallery_page(scope(user), "#{gallery.id}")

      assert page.gallery.id == gallery.id
      # The images page carries {image, hit} tuples, not bare image structs.
      assert image.id in Enum.map(page.images, fn {img, _hit} -> img.id end)
      assert is_boolean(page.watching)
      assert is_boolean(page.gallery_prev)
      assert is_boolean(page.gallery_next)
      assert is_list(page.interactions)
    end

    test "an anonymous viewer sees an empty gallery's page" do
      gallery = gallery_fixture(confirmed_user_fixture())
      SearchHelpers.reindex_all!(Image)

      assert {:ok, %GalleryPage{} = page} =
               Galleries.load_gallery_page(scope(nil), "#{gallery.id}")

      assert page.gallery.id == gallery.id
      assert Enum.empty?(page.images)
    end

    test "an unknown id is unauthorized for an anonymous viewer" do
      assert Galleries.load_gallery_page(scope(nil), "999999999") == {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Galleries.load_gallery_page(scope(nil), "abc") == {:error, :not_found}
    end
  end

  describe "load_gallery_index/2" do
    test "a title filter finds a matching gallery and excludes others" do
      user = confirmed_user_fixture()
      wanted = gallery_fixture(user, title: "Test Wanted Gallery")
      other = gallery_fixture(user, title: "Test Unrelated Gallery")
      SearchHelpers.reindex_all!(Gallery)

      page = Galleries.load_gallery_index(%{"gallery" => %{"title" => "wanted"}}, @pagination)

      ids = Enum.map(page.entries, & &1.id)
      assert wanted.id in ids
      refute other.id in ids
    end

    test "no filter returns the gallery with its thumbnail preloaded" do
      user = confirmed_user_fixture()
      gallery = gallery_fixture(user)
      SearchHelpers.reindex_all!(Gallery)

      page = Galleries.load_gallery_index(%{}, @pagination)

      assert [%Gallery{} = loaded] = Enum.filter(page.entries, &(&1.id == gallery.id))
      # The thumbnail association is loaded, not left as a lazy placeholder.
      refute match?(%Ecto.Association.NotLoaded{}, loaded.thumbnail)
    end
  end
end
