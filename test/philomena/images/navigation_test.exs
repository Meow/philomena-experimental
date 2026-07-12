defmodule Philomena.Images.NavigationTest do
  @moduledoc """
  Context-level tests for the image navigation loaders on `Philomena.Images`:
  prev/next lookup, the search-index page number, related images, and the
  random-image picker.

  All four run a search scoped to a viewer, so they are asserted against the
  real OpenSearch index. Each loads its subject image by id and authorizes it
  for `:show`, so they share the navigation authorization matrix: a
  non-castable id is not found, an unknown id is unauthorized for a viewer
  with no blanket rule and not found for an admin.
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Images.Search.Scope
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  setup do
    Search.clear_index!(Image)
    :ok
  end

  # The compiled filter body the web layer produces for a viewer with no active
  # filter: an empty tag_ids exclusion plus a pair of match_none clauses, so it
  # excludes nothing.
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

  defp scope(overrides \\ []) do
    %Scope{
      user: Keyword.get(overrides, :user),
      filter: Keyword.get(overrides, :filter, default_filter()),
      params: Keyword.get(overrides, :params, %{}),
      pagination: Keyword.get(overrides, :pagination, %{page_number: 1, page_size: 25})
    }
  end

  defp hours_ago(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  # Two images ordered by first_seen_at, the default descending sort; `newer`
  # precedes `older` in the listing.
  defp two_images do
    older = image_fixture(first_seen_at: hours_ago(2))
    newer = image_fixture(first_seen_at: hours_ago(1))
    SearchHelpers.reindex_all!(Image)

    {older, newer}
  end

  describe "find_consecutive_image/2" do
    test "rel=next finds the older image and carries a sort cursor" do
      {older, newer} = two_images()

      assert {:ok, {image, {adjacent, hit}}} =
               Images.find_consecutive_image(
                 scope(params: %{"rel" => "next"}),
                 to_string(newer.id)
               )

      assert image.id == newer.id
      assert adjacent.id == older.id
      assert Map.has_key?(hit, "sort")
    end

    test "rel=prev finds the newer image" do
      {older, newer} = two_images()

      assert {:ok, {image, {adjacent, _hit}}} =
               Images.find_consecutive_image(
                 scope(params: %{"rel" => "prev"}),
                 to_string(older.id)
               )

      assert image.id == older.id
      assert adjacent.id == newer.id
    end

    test "returns a nil neighbor at the end of the sequence" do
      {older, _newer} = two_images()

      assert {:ok, {image, nil}} =
               Images.find_consecutive_image(
                 scope(params: %{"rel" => "next"}),
                 to_string(older.id)
               )

      assert image.id == older.id
    end

    test "accepts an integer id" do
      {older, newer} = two_images()

      assert {:ok, {image, {adjacent, _hit}}} =
               Images.find_consecutive_image(scope(params: %{"rel" => "next"}), newer.id)

      assert image.id == newer.id
      assert adjacent.id == older.id
    end

    test "an unknown well-formed id is unauthorized for an anonymous viewer" do
      # The image loads as nil and a nil viewer fails :show on the nil load, so
      # the missing image surfaces as unauthorized rather than not found.
      assert Images.find_consecutive_image(scope(params: %{"rel" => "next"}), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :show on the nil load via the blanket rule, then the
      # image presence check fails, so the missing image is not found.
      scope = scope(user: admin_user_fixture(), params: %{"rel" => "next"})

      assert Images.find_consecutive_image(scope, "2147483647") == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.find_consecutive_image(scope(params: %{"rel" => "next"}), "not-a-number") ==
               {:error, :not_found}
    end
  end

  describe "find_image_index_page/2" do
    test "returns the page number as a string" do
      {older, newer} = two_images()

      # Listed by descending id, the newer image has no images ahead of it, so
      # it sits on page one; the older image trails it but still on page one at
      # the default page size.
      assert Images.find_image_index_page(scope(), to_string(newer.id)) == {:ok, "1"}
      assert Images.find_image_index_page(scope(), to_string(older.id)) == {:ok, "1"}
    end

    test "the scope's page size drives the page number" do
      {older, _newer} = two_images()

      # One image precedes the older one; a page size of one puts it on page two.
      scope = scope(pagination: %{page_number: 1, page_size: 1})

      assert Images.find_image_index_page(scope, to_string(older.id)) == {:ok, "2"}
    end

    test "accepts an integer id" do
      {_older, newer} = two_images()

      assert Images.find_image_index_page(scope(), newer.id) == {:ok, "1"}
    end

    test "an unknown well-formed id is unauthorized for an anonymous viewer" do
      assert Images.find_image_index_page(scope(), "2147483647") == {:error, :unauthorized}
    end

    test "a non-castable id is not found" do
      assert Images.find_image_index_page(scope(), "not-a-number") == {:error, :not_found}
    end
  end

  describe "related_images/2" do
    test "an image sharing a tag lists the related image" do
      image = image_fixture(tags: "safe, test related subject")
      related = image_fixture(tags: "safe, test related subject")
      SearchHelpers.reindex_all!(Image)

      assert {:ok, {loaded, page}} = Images.related_images(scope(), to_string(image.id))
      assert loaded.id == image.id
      assert related.id in Enum.map(page.entries, & &1.id)
      # The subject image never appears among its own related results.
      refute image.id in Enum.map(page.entries, & &1.id)
    end

    test "an image with no shared tags still succeeds with an empty page" do
      # Only the rating tag is present, and ratings are excluded from matching,
      # so there is nothing to relate against.
      image = image_fixture()
      SearchHelpers.reindex_all!(Image)

      assert {:ok, {loaded, page}} = Images.related_images(scope(), to_string(image.id))
      assert loaded.id == image.id
      assert page.entries == []
    end

    test "accepts an integer id" do
      image = image_fixture()
      SearchHelpers.reindex_all!(Image)

      assert {:ok, {loaded, _page}} = Images.related_images(scope(), image.id)
      assert loaded.id == image.id
    end

    test "an unknown well-formed id is unauthorized for an anonymous viewer" do
      assert Images.related_images(scope(), "2147483647") == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      assert Images.related_images(scope(user: admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.related_images(scope(), "not-a-number") == {:error, :not_found}
    end
  end

  describe "random_image_id/1" do
    test "returns the id of the only matching image" do
      image = image_fixture()
      SearchHelpers.reindex_all!(Image)

      assert Images.random_image_id(scope()) == image.id
    end

    test "returns nil when the index is empty" do
      assert Images.random_image_id(scope()) == nil
    end

    test "restricts the pool to the q parameter" do
      _other = image_fixture(tags: "safe")
      wanted = image_fixture(tags: "safe, test wanted tag")
      SearchHelpers.reindex_all!(Image)

      assert Images.random_image_id(scope(params: %{"q" => "test wanted tag"})) == wanted.id
    end

    test "returns nil for a malformed query string" do
      # An unbalanced parenthesis fails to compile, and the picker treats a
      # malformed query as an empty pool.
      _image = image_fixture()
      SearchHelpers.reindex_all!(Image)

      assert Images.random_image_id(scope(params: %{"q" => "((("})) == nil
    end
  end
end
