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
end
