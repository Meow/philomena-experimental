defmodule Philomena.SourceChangesTest do
  @moduledoc """
  Context-level tests for the actor-first read API on `Philomena.SourceChanges`:
  `image_source_changes/3`.

  These pin the id parsing, the `:show` authorization on the possibly-nil image
  load (including the admin/other-actor divergence on an unknown id), and the
  paginated, newest-first result on success.

  The actor here is a plain `User.t()` or `nil`, matching what the controller
  hands in as `conn.assigns.current_user`.
  """

  use Philomena.DataCase, async: true

  alias Philomena.SourceChanges
  alias Scrivener.Page

  import Philomena.ImagesFixtures
  import Philomena.SourceChangesFixtures
  import Philomena.UsersFixtures

  @pagination [page: 1, page_size: 25]

  describe "image_source_changes/3" do
    test "an anonymous actor lists a public image's source changes newest-first" do
      image = image_fixture()
      older = source_change_fixture(image)
      newer = source_change_fixture(image)

      assert {:ok, {loaded_image, %Page{} = page}} =
               SourceChanges.image_source_changes(nil, to_string(image.id), @pagination)

      assert loaded_image.id == image.id
      assert Enum.map(page.entries, & &1.id) == [newer.id, older.id]
    end

    test "a regular user lists a public image's source changes" do
      user = confirmed_user_fixture()
      image = image_fixture()
      change = source_change_fixture(image)

      assert {:ok, {loaded_image, page}} =
               SourceChanges.image_source_changes(user, to_string(image.id), @pagination)

      assert loaded_image.id == image.id
      assert Enum.map(page.entries, & &1.id) == [change.id]
    end

    test "the result preloads each change's user" do
      user = confirmed_user_fixture()
      image = image_fixture()
      source_change_fixture(image, user_id: user.id)

      assert {:ok, {_image, page}} =
               SourceChanges.image_source_changes(nil, to_string(image.id), @pagination)

      [entry] = page.entries
      assert entry.user.id == user.id
    end

    test "page_size caps the entries and reports the total" do
      image = image_fixture()
      for _ <- 1..3, do: source_change_fixture(image)

      assert {:ok, {_image, page}} =
               SourceChanges.image_source_changes(nil, to_string(image.id), page: 1, page_size: 2)

      assert page.page_size == 2
      assert length(page.entries) == 2
      assert page.total_entries == 3
    end

    test "an image with no source changes yields an empty page" do
      image = image_fixture()

      assert {:ok, {loaded_image, page}} =
               SourceChanges.image_source_changes(nil, to_string(image.id), @pagination)

      assert loaded_image.id == image.id
      assert page.entries == []
      assert page.total_entries == 0
    end

    test "accepts an integer id" do
      image = image_fixture()
      change = source_change_fixture(image)

      assert {:ok, {_image, page}} =
               SourceChanges.image_source_changes(nil, image.id, @pagination)

      assert Enum.map(page.entries, & &1.id) == [change.id]
    end

    test "an unknown well-formed id is unauthorized for an anonymous actor" do
      # The image loads as nil and a nil actor fails :show on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      assert SourceChanges.image_source_changes(nil, "2147483647", @pagination) ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a regular user" do
      assert SourceChanges.image_source_changes(
               confirmed_user_fixture(),
               "2147483647",
               @pagination
             ) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator" do
      assert SourceChanges.image_source_changes(
               moderator_user_fixture(),
               "2147483647",
               @pagination
             ) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :show on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      assert SourceChanges.image_source_changes(
               admin_user_fixture(),
               "2147483647",
               @pagination
             ) == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert SourceChanges.image_source_changes(nil, "not-a-number", @pagination) ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, ahead of any authorization.
      assert SourceChanges.image_source_changes(nil, "99999999999999999999", @pagination) ==
               {:error, :not_found}
    end
  end

  describe "user_source_changes/4" do
    test "an anonymous actor lists a user's source changes newest-first" do
      user = confirmed_user_fixture()
      image = image_fixture()
      older = source_change_fixture(image, user_id: user.id)
      newer = source_change_fixture(image, user_id: user.id)

      assert {:ok, {loaded_user, %Page{} = page, image_count}} =
               SourceChanges.user_source_changes(nil, user.slug, %{}, @pagination)

      assert loaded_user.id == user.id
      assert Enum.map(page.entries, & &1.id) == [newer.id, older.id]
      assert image_count == 1
    end

    test "excludes changes to the user's own anonymous uploads" do
      user = confirmed_user_fixture()
      anon_image = image_fixture(%{user_id: user.id, anonymous: true})
      public_image = image_fixture()
      source_change_fixture(anon_image, user_id: user.id)
      kept = source_change_fixture(public_image, user_id: user.id)

      assert {:ok, {_user, page, image_count}} =
               SourceChanges.user_source_changes(nil, user.slug, %{}, @pagination)

      # The change on the user's own anonymous upload is dropped; only the change
      # on the public image survives.
      assert Enum.map(page.entries, & &1.id) == [kept.id]
      assert image_count == 1
    end

    test "the added filter narrows to additions" do
      user = confirmed_user_fixture()
      image = image_fixture()
      added = source_change_fixture(image, user_id: user.id, added: true)
      source_change_fixture(image, user_id: user.id, added: false)

      assert {:ok, {_user, page, _count}} =
               SourceChanges.user_source_changes(nil, user.slug, %{"added" => "1"}, @pagination)

      assert Enum.map(page.entries, & &1.id) == [added.id]
    end

    test "the added filter narrows to removals" do
      user = confirmed_user_fixture()
      image = image_fixture()
      source_change_fixture(image, user_id: user.id, added: true)
      removed = source_change_fixture(image, user_id: user.id, added: false)

      assert {:ok, {_user, page, _count}} =
               SourceChanges.user_source_changes(nil, user.slug, %{"added" => "0"}, @pagination)

      assert Enum.map(page.entries, & &1.id) == [removed.id]
    end

    test "image_count reports the number of distinct images touched" do
      user = confirmed_user_fixture()
      image = image_fixture()
      other = image_fixture()
      source_change_fixture(image, user_id: user.id)
      source_change_fixture(image, user_id: user.id)
      source_change_fixture(other, user_id: user.id)

      assert {:ok, {_user, _page, image_count}} =
               SourceChanges.user_source_changes(nil, user.slug, %{}, @pagination)

      assert image_count == 2
    end

    test "page_size caps the entries and reports the total" do
      user = confirmed_user_fixture()
      image = image_fixture()
      for _ <- 1..3, do: source_change_fixture(image, user_id: user.id)

      assert {:ok, {_user, page, _count}} =
               SourceChanges.user_source_changes(nil, user.slug, %{}, page: 1, page_size: 2)

      assert page.page_size == 2
      assert length(page.entries) == 2
      assert page.total_entries == 3
    end

    test "an unknown slug is unauthorized for an anonymous actor, not-found for an admin" do
      assert SourceChanges.user_source_changes(nil, "no-such-user", %{}, @pagination) ==
               {:error, :unauthorized}

      assert SourceChanges.user_source_changes(
               admin_user_fixture(),
               "no-such-user",
               %{},
               @pagination
             ) == {:error, :not_found}
    end
  end

  describe "count_for_image/1" do
    test "returns the number of source changes for the image" do
      image = image_fixture()
      source_change_fixture(image)
      source_change_fixture(image)

      assert SourceChanges.count_for_image(image.id) == 2
    end

    test "counts only the given image's changes" do
      image = image_fixture()
      other = image_fixture()
      source_change_fixture(image)
      source_change_fixture(other)

      assert SourceChanges.count_for_image(image.id) == 1
    end

    test "returns zero when the image has no source changes" do
      image = image_fixture()

      assert SourceChanges.count_for_image(image.id) == 0
    end
  end

  describe "ip_source_changes/4" do
    test "a moderator lists the changes attributed to an address, newest first" do
      image = image_fixture()
      older = source_change_fixture(image, ip: "203.0.113.5")
      newer = source_change_fixture(image, ip: "203.0.113.5")

      assert {:ok, {%Postgrex.INET{} = ip, %Postgrex.INET{} = range, page}} =
               SourceChanges.ip_source_changes(
                 moderator_user_fixture(),
                 "203.0.113.5",
                 %{},
                 @pagination
               )

      assert ip == range
      assert Enum.map(page.entries, & &1.id) == [newer.id, older.id]
    end

    test "the mask param widens the query to a subnet" do
      image = image_fixture()
      change = source_change_fixture(image, ip: "203.0.113.5")

      assert {:ok, {_ip, range, page}} =
               SourceChanges.ip_source_changes(
                 admin_user_fixture(),
                 "203.0.113.5",
                 %{"mask" => "24"},
                 @pagination
               )

      assert range.netmask == 24
      assert change.id in Enum.map(page.entries, & &1.id)
    end

    test "the added filter narrows to additions" do
      image = image_fixture()
      added = source_change_fixture(image, ip: "203.0.113.6", added: true)
      source_change_fixture(image, ip: "203.0.113.6", added: false)

      assert {:ok, {_ip, _range, page}} =
               SourceChanges.ip_source_changes(
                 moderator_user_fixture(),
                 "203.0.113.6",
                 %{"added" => "1"},
                 @pagination
               )

      assert Enum.map(page.entries, & &1.id) == [added.id]
    end

    test "a staffer submitting an unparsable address is not-found" do
      assert SourceChanges.ip_source_changes(
               moderator_user_fixture(),
               "not-an-ip",
               %{},
               @pagination
             ) == {:error, :not_found}
    end

    test "a regular user is unauthorized before the address is parsed" do
      assert SourceChanges.ip_source_changes(
               confirmed_user_fixture(),
               "garbage",
               %{},
               @pagination
             ) == {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized" do
      assert SourceChanges.ip_source_changes(nil, "203.0.113.5", %{}, @pagination) ==
               {:error, :unauthorized}
    end
  end

  describe "fingerprint_source_changes/4" do
    test "a moderator lists the changes attributed to a fingerprint, newest first" do
      image = image_fixture()
      older = source_change_fixture(image, fingerprint: "abc123")
      newer = source_change_fixture(image, fingerprint: "abc123")

      assert {:ok, page} =
               SourceChanges.fingerprint_source_changes(
                 moderator_user_fixture(),
                 "abc123",
                 %{},
                 @pagination
               )

      assert Enum.map(page.entries, & &1.id) == [newer.id, older.id]
    end

    test "any raw string is accepted and returns a possibly-empty page" do
      assert {:ok, page} =
               SourceChanges.fingerprint_source_changes(
                 admin_user_fixture(),
                 "no-such-fingerprint",
                 %{},
                 @pagination
               )

      assert page.entries == []
    end

    test "the added filter narrows to removals" do
      image = image_fixture()
      source_change_fixture(image, fingerprint: "def456", added: true)
      removed = source_change_fixture(image, fingerprint: "def456", added: false)

      assert {:ok, page} =
               SourceChanges.fingerprint_source_changes(
                 moderator_user_fixture(),
                 "def456",
                 %{"added" => "0"},
                 @pagination
               )

      assert Enum.map(page.entries, & &1.id) == [removed.id]
    end

    test "a regular user is unauthorized" do
      assert SourceChanges.fingerprint_source_changes(
               confirmed_user_fixture(),
               "abc123",
               %{},
               @pagination
             ) == {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized" do
      assert SourceChanges.fingerprint_source_changes(nil, "abc123", %{}, @pagination) ==
               {:error, :unauthorized}
    end
  end
end
