defmodule Philomena.CommentsTest do
  @moduledoc """
  Context-level tests for `Philomena.Comments.search_comments/4`, which runs a
  comment search against OpenSearch and applies the viewer's visibility rules.
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.CommentsFixtures
  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

  alias Philomena.Comments
  alias Philomena.Filters.Filter
  alias Philomena.Repo
  alias Philomena.Comments.Comment
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  setup do
    Search.clear_index!(Comment)
    :ok
  end

  @pagination %{page_number: 1, page_size: 25}
  @empty_filter %Filter{hidden_tag_ids: []}

  describe "search_comments/4" do
    test "returns an error for an uncompilable query string" do
      assert {:error, msg} =
               Comments.search_comments(
                 nil,
                 @empty_filter,
                 "created_at.gte:not-a-date",
                 @pagination
               )

      assert is_binary(msg)
    end

    test "finds an indexed comment with preloads for an anonymous viewer" do
      user = user_fixture()
      image = image_fixture()
      comment = comment_fixture(image, user, %{"body" => "Test grapefruit comment"})
      SearchHelpers.reindex_all!(Comment)

      assert {:ok, results} =
               Comments.search_comments(nil, @empty_filter, "grapefruit", @pagination)

      assert [entry] = results.entries
      assert entry.id == comment.id

      # Display preloads are loaded on the returned records.
      assert %Philomena.Users.User{} = entry.user
      assert is_list(entry.image.tags)
      assert is_list(entry.image.sources)
    end

    test "excludes a hidden comment from an anonymous viewer" do
      image = image_fixture()
      comment = comment_fixture(image, nil, %{"body" => "Test grapefruit comment"})

      comment
      |> Ecto.Changeset.change(hidden_from_users: true)
      |> Repo.update!()

      SearchHelpers.reindex_all!(Comment)

      assert {:ok, results} =
               Comments.search_comments(nil, @empty_filter, "grapefruit", @pagination)

      assert results.entries == []
    end

    test "includes a hidden comment for a moderator" do
      moderator = moderator_user_fixture()
      image = image_fixture()
      comment = comment_fixture(image, nil, %{"body" => "Test grapefruit comment"})

      comment
      |> Ecto.Changeset.change(hidden_from_users: true)
      |> Repo.update!()

      SearchHelpers.reindex_all!(Comment)

      assert {:ok, results} =
               Comments.search_comments(moderator, @empty_filter, "grapefruit", @pagination)

      assert [entry] = results.entries
      assert entry.id == comment.id
    end

    test "excludes a comment on an image carrying a hidden tag" do
      image = image_fixture(tags: "grimdark")
      tag = Enum.find(image.tags, &(&1.name == "grimdark"))
      _comment = comment_fixture(image, nil, %{"body" => "Test grapefruit comment"})
      SearchHelpers.reindex_all!(Comment)

      hidden_filter = %Filter{hidden_tag_ids: [tag.id]}

      assert {:ok, results} =
               Comments.search_comments(nil, hidden_filter, "grapefruit", @pagination)

      assert results.entries == []

      # The same comment is visible when the tag is not hidden.
      assert {:ok, results} =
               Comments.search_comments(nil, @empty_filter, "grapefruit", @pagination)

      assert [_entry] = results.entries
    end
  end
end
