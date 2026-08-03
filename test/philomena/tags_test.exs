defmodule Philomena.TagsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.Tags` functions and
  the `TagPage` struct.

  These pin the per-role authorization matrices on the edit/alias/delete/image
  paths, the unknown-slug split (an admin passes authorization on the nil tag
  and gets `:not_found`; anyone else gets `:unauthorized`), the byte-exact
  moderation logs the write paths emit, and the two search-backed loaders
  (`search_tags/3` and `load_tag_page/2`).
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.AttributionFixtures, only: [actor: 0, actor: 1]
  import Philomena.FiltersFixtures
  import Philomena.ImagesFixtures
  import Philomena.TagsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Tags
  alias Philomena.Tags.Tag
  alias Philomena.Tags.TagPage
  alias Philomena.Images.Image
  alias Philomena.Images.Search.Scope
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Repo
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  @pagination %{page_number: 1, page_size: 25}

  @limit Tag.name_length_limit()

  setup do
    Search.clear_index!(Tag)
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

  defp only_moderation_log!, do: Repo.one!(ModerationLog)

  defp moderation_log_count, do: Repo.aggregate(ModerationLog, :count)

  describe "search_tags/3" do
    test "finds an indexed tag by a wildcard query, carrying the default preloads" do
      tag = tag_fixture()
      SearchHelpers.reindex_all!(Tag)

      assert {:ok, tags} = Tags.search_tags("*", @pagination)
      assert %Tag{} = found = Enum.find(tags, &(&1.id == tag.id))
      assert Ecto.assoc_loaded?(found.aliases)
      assert Ecto.assoc_loaded?(found.dnp_entries)
    end

    test "a missing query compiles to match-none, returning an empty page" do
      tag_fixture()
      SearchHelpers.reindex_all!(Tag)

      assert {:ok, tags} = Tags.search_tags(nil, @pagination)
      assert Enum.empty?(tags)
    end

    test ":page_size fixes the result window and :preload replaces the default associations" do
      tag = tag_fixture()
      SearchHelpers.reindex_all!(Tag)

      assert {:ok, tags} = Tags.search_tags("*", @pagination, page_size: 250, preload: [])
      assert tags.page_size == 250
      assert %Tag{} = found = Enum.find(tags, &(&1.id == tag.id))
      refute Ecto.assoc_loaded?(found.aliases)
    end

    test "a malformed query returns the compiler error" do
      assert {:error, msg} = Tags.search_tags("(", @pagination)
      assert is_binary(msg)
    end
  end

  describe "load_tag_page/2" do
    test "assembles the page for a real tag, carrying its tagged image" do
      created_at = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      image = image_fixture(tags: "safe", created_at: created_at)
      tag = Tags.get_tag_by_name("safe")
      SearchHelpers.reindex_all!(Image)

      assert {:ok, %TagPage{} = page} = Tags.load_tag_page(scope(nil), tag.slug)

      assert page.tag.id == tag.id
      assert image.id in Enum.map(page.images, & &1.id)
      assert is_list(page.interactions)
      # A tag whose name compiles back to itself is used verbatim.
      assert page.search_query == "safe"
    end

    test "an aliased tag reports the tag it is aliased into" do
      target = tag_fixture(name: "load page target")

      aliased =
        tag_fixture()
        |> Ecto.Changeset.change(aliased_tag_id: target.id)
        |> Repo.update!()

      assert {:aliased_to, %Tag{} = returned} = Tags.load_tag_page(scope(nil), aliased.slug)
      assert returned.id == aliased.id
      assert returned.aliased_tag.id == target.id
    end

    test "an unknown slug is unauthorized for anonymous, regular, and moderator viewers" do
      assert Tags.load_tag_page(scope(nil), "nonexistent-tag") == {:error, :unauthorized}

      assert Tags.load_tag_page(scope(confirmed_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}

      assert Tags.load_tag_page(scope(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin" do
      assert Tags.load_tag_page(scope(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
    end
  end

  describe "load_tag_for_edit/3" do
    test "a moderator loads the tag paired with its edit changeset" do
      tag = tag_fixture()

      assert {:ok, {%Tag{} = loaded, %Ecto.Changeset{} = changeset}} =
               Tags.load_tag_for_edit(actor(moderator_user_fixture()), tag.slug)

      assert loaded.id == tag.id
      assert changeset.data.id == tag.id
    end

    test "anonymous and regular users are unauthorized" do
      tag = tag_fixture()

      assert Tags.load_tag_for_edit(actor(), tag.slug) == {:error, :unauthorized}

      assert Tags.load_tag_for_edit(actor(confirmed_user_fixture()), tag.slug) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.load_tag_for_edit(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.load_tag_for_edit(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end
  end

  describe "update_tag/3" do
    test "a moderator updates the tag and writes a moderation log" do
      tag = tag_fixture()

      assert {:ok, %Tag{} = updated} =
               Tags.update_tag(actor(moderator_user_fixture()), tag.slug, %{
                 "category" => "rating"
               })

      assert updated.id == tag.id
      assert Repo.reload!(tag).category == "rating"

      log = only_moderation_log!()
      assert log.type == "Tag:update"
      assert log.subject_path == Paths.tag_path(tag)
      assert log.body == "Updated details on tag '#{tag.name}'"
    end

    test "a category outside the allowed list is a rejected changeset and writes no log" do
      tag = tag_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tags.update_tag(actor(moderator_user_fixture()), tag.slug, %{"category" => "bogus"})

      refute changeset.valid?
      assert Repo.reload!(tag).category == tag.category
      assert moderation_log_count() == 0
    end

    test "updating to another allowed category succeeds and writes a log" do
      tag = tag_fixture()

      assert {:ok, %Tag{}} =
               Tags.update_tag(actor(moderator_user_fixture()), tag.slug, %{
                 "category" => "species"
               })

      assert Repo.reload!(tag).category == "species"
      assert only_moderation_log!().type == "Tag:update"
    end

    test "anonymous and regular users are unauthorized and change nothing" do
      tag = tag_fixture()

      assert Tags.update_tag(actor(), tag.slug, %{"category" => "rating"}) ==
               {:error, :unauthorized}

      assert Tags.update_tag(actor(confirmed_user_fixture()), tag.slug, %{"category" => "rating"}) ==
               {:error, :unauthorized}

      assert Repo.reload!(tag).category == tag.category
      assert moderation_log_count() == 0
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.update_tag(actor(admin_user_fixture()), "nonexistent-tag", %{
               "category" => "rating"
             }) ==
               {:error, :not_found}

      assert Tags.update_tag(actor(moderator_user_fixture()), "nonexistent-tag", %{
               "category" => "rating"
             }) == {:error, :unauthorized}
    end
  end

  describe "delete_tag/2" do
    test "an admin queues the deletion and writes a moderation log" do
      tag = tag_fixture()

      assert {:ok, %Tag{} = deleted} = Tags.delete_tag(actor(admin_user_fixture()), tag.slug)
      assert deleted.id == tag.id
      # Deletion is performed asynchronously by the worker; the row is still
      # present synchronously.
      assert Repo.get(Tag, tag.id)

      log = only_moderation_log!()
      assert log.type == "Tag:delete"
      assert log.subject_path == Paths.tag_path(tag)
      assert log.body == "Deleted tag '#{tag.name}'"
    end

    test "a plain moderator lacks :delete and is unauthorized" do
      tag = tag_fixture()

      assert Tags.delete_tag(actor(moderator_user_fixture()), tag.slug) == {:error, :unauthorized}
      assert Repo.get(Tag, tag.id)
      assert moderation_log_count() == 0
    end

    test "anonymous and regular users are unauthorized" do
      tag = tag_fixture()

      assert Tags.delete_tag(actor(), tag.slug) == {:error, :unauthorized}
      assert Tags.delete_tag(actor(confirmed_user_fixture()), tag.slug) == {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.delete_tag(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.delete_tag(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end
  end

  describe "load_tag_alias_for_edit/2" do
    test "an admin loads the tag paired with its edit changeset" do
      tag = tag_fixture()

      assert {:ok, {%Tag{} = loaded, %Ecto.Changeset{}}} =
               Tags.load_tag_alias_for_edit(actor(admin_user_fixture()), tag.slug)

      assert loaded.id == tag.id
    end

    test "a plain moderator lacks :alias and is unauthorized" do
      tag = tag_fixture()

      assert Tags.load_tag_alias_for_edit(actor(moderator_user_fixture()), tag.slug) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.load_tag_alias_for_edit(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.load_tag_alias_for_edit(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end
  end

  describe "alias_tag/3" do
    test "an admin aliases the tag into the target and writes a moderation log" do
      target = tag_fixture(name: "alias context target")
      tag = tag_fixture()

      assert {:ok, %Tag{} = aliased} =
               Tags.alias_tag(actor(admin_user_fixture()), tag.slug, %{
                 "target_tag" => target.name
               })

      assert aliased.id == tag.id
      assert Repo.reload!(tag).aliased_tag_id == target.id

      log = only_moderation_log!()
      assert log.type == "Tag.Alias:update"
      assert log.subject_path == Paths.tag_path(tag)
      assert log.body == "Aliased tag '#{tag.name}' into '#{target.name}'"
    end

    test "aliasing into an unknown target is a rejected changeset and writes no log" do
      tag = tag_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tags.alias_tag(actor(admin_user_fixture()), tag.slug, %{
                 "target_tag" => "no such tag"
               })

      refute changeset.valid?
      assert Repo.reload!(tag).aliased_tag_id == nil
      assert moderation_log_count() == 0
    end

    test "a plain moderator lacks :alias and is unauthorized" do
      target = tag_fixture(name: "alias mod target")
      tag = tag_fixture()

      assert Tags.alias_tag(actor(moderator_user_fixture()), tag.slug, %{
               "target_tag" => target.name
             }) ==
               {:error, :unauthorized}

      assert Repo.reload!(tag).aliased_tag_id == nil
    end

    test "anonymous and regular users are unauthorized" do
      target = tag_fixture(name: "alias anon target")
      tag = tag_fixture()

      assert Tags.alias_tag(actor(), tag.slug, %{"target_tag" => target.name}) ==
               {:error, :unauthorized}

      assert Tags.alias_tag(actor(confirmed_user_fixture()), tag.slug, %{
               "target_tag" => target.name
             }) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.alias_tag(actor(admin_user_fixture()), "nonexistent-tag", %{"target_tag" => "x"}) ==
               {:error, :not_found}

      assert Tags.alias_tag(actor(moderator_user_fixture()), "nonexistent-tag", %{
               "target_tag" => "x"
             }) ==
               {:error, :unauthorized}
    end
  end

  describe "unalias_tag/2" do
    test "an admin queues a dealias and writes a moderation log" do
      target = tag_fixture(name: "dealias context target")

      tag =
        tag_fixture()
        |> Ecto.Changeset.change(aliased_tag_id: target.id)
        |> Repo.update!()

      assert {:ok, %Tag{} = returned} = Tags.unalias_tag(actor(admin_user_fixture()), tag.slug)
      assert returned.id == tag.id

      log = only_moderation_log!()
      assert log.type == "Tag.Alias:delete"
      assert log.subject_path == Paths.tag_path(tag)
      assert log.body == "Dealiased tag '#{tag.name}'"
    end

    test "a plain moderator lacks :alias and is unauthorized" do
      tag = tag_fixture()

      assert Tags.unalias_tag(actor(moderator_user_fixture()), tag.slug) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.unalias_tag(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.unalias_tag(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end
  end

  describe "tag_detail/2" do
    test "a moderator gets the spoilering/hiding filters and watching users" do
      tag = tag_fixture()

      spoiler_owner = confirmed_user_fixture()
      hide_owner = confirmed_user_fixture()
      spoiler_filter = filter_fixture(spoiler_owner, %{spoilered_tag_list: tag.name})
      hide_filter = filter_fixture(hide_owner, %{hidden_tag_list: tag.name})

      watcher =
        confirmed_user_fixture()
        |> Ecto.Changeset.change(watched_tag_ids: [tag.id])
        |> Repo.update!()

      assert {:ok, detail} = Tags.tag_detail(actor(moderator_user_fixture()), tag.slug)

      assert detail.tag.id == tag.id
      assert Enum.map(detail.filters_spoilering, & &1.id) == [spoiler_filter.id]
      assert Enum.map(detail.filters_hiding, & &1.id) == [hide_filter.id]
      assert Enum.map(detail.users_watching, & &1.id) == [watcher.id]
    end

    test "a fresh tag has empty usage lists" do
      tag = tag_fixture()

      assert {:ok, detail} = Tags.tag_detail(actor(moderator_user_fixture()), tag.slug)
      assert detail.filters_spoilering == []
      assert detail.filters_hiding == []
      assert detail.users_watching == []
    end

    # Authorization runs on an empty tag struct before the slug loads, so an
    # unprivileged actor is unauthorized even naming a tag that does not exist.
    test "anonymous and regular users are unauthorized even for an unknown slug" do
      assert Tags.tag_detail(actor(), "nonexistent-tag") == {:error, :unauthorized}

      assert Tags.tag_detail(actor(confirmed_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end

    test "a permitted moderator gets not-found for an unknown slug" do
      assert Tags.tag_detail(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
    end
  end

  describe "load_tag_for_edit/3 with :preload" do
    test "the option replaces the default preloads" do
      tag = tag_fixture()

      assert {:ok, {%Tag{} = loaded, %Ecto.Changeset{}}} =
               Tags.load_tag_for_edit(actor(moderator_user_fixture()), tag.slug,
                 preload: [:implied_tags]
               )

      assert loaded.id == tag.id
      assert Ecto.assoc_loaded?(loaded.implied_tags)
      refute Ecto.assoc_loaded?(loaded.aliases)
    end
  end

  describe "update_tag_image/3" do
    test "a moderator uploads the spoiler image and writes a moderation log" do
      tag = tag_fixture()

      assert {:ok, %Tag{} = updated} =
               Tags.update_tag_image(actor(moderator_user_fixture()), tag.slug, %{
                 "image" => png_upload()
               })

      assert updated.id == tag.id
      reloaded = Repo.reload!(tag)
      assert reloaded.image
      assert reloaded.image_mime_type == "image/png"

      log = only_moderation_log!()
      assert log.type == "Tag.Image:update"
      assert log.subject_path == Paths.tag_path(tag)
      assert log.body == "Updated image on tag '#{tag.name}'"
    end

    test "an upload with no file is a rejected changeset and writes no log" do
      tag = tag_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Tags.update_tag_image(actor(moderator_user_fixture()), tag.slug, %{})

      assert moderation_log_count() == 0
    end

    test "anonymous and regular users are unauthorized" do
      tag = tag_fixture()

      assert Tags.update_tag_image(actor(), tag.slug, %{"image" => png_upload()}) ==
               {:error, :unauthorized}

      assert Tags.update_tag_image(actor(confirmed_user_fixture()), tag.slug, %{
               "image" => png_upload()
             }) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.update_tag_image(actor(admin_user_fixture()), "nonexistent-tag", %{
               "image" => png_upload()
             }) == {:error, :not_found}

      assert Tags.update_tag_image(actor(moderator_user_fixture()), "nonexistent-tag", %{
               "image" => png_upload()
             }) == {:error, :unauthorized}
    end
  end

  describe "remove_tag_image/2" do
    test "a moderator removes the spoiler image and writes a moderation log" do
      tag =
        tag_fixture()
        |> Ecto.Changeset.change(image: "2024/1/1/abc.png")
        |> Repo.update!()

      assert {:ok, %Tag{} = updated} =
               Tags.remove_tag_image(actor(moderator_user_fixture()), tag.slug)

      assert updated.id == tag.id
      assert Repo.reload!(tag).image == nil

      log = only_moderation_log!()
      assert log.type == "Tag.Image:delete"
      assert log.subject_path == Paths.tag_path(tag)
      assert log.body == "Removed image on tag '#{tag.name}'"
    end

    test "anonymous and regular users are unauthorized" do
      tag = tag_fixture()

      assert Tags.remove_tag_image(actor(), tag.slug) == {:error, :unauthorized}

      assert Tags.remove_tag_image(actor(confirmed_user_fixture()), tag.slug) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.remove_tag_image(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.remove_tag_image(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end
  end

  describe "reindex_tag_by_slug/2" do
    test "an admin queues the reindex and gets the tag back" do
      tag = tag_fixture()

      assert {:ok, %Tag{} = returned} =
               Tags.reindex_tag_by_slug(actor(admin_user_fixture()), tag.slug)

      assert returned.id == tag.id
      # No moderation log is written for a reindex.
      assert moderation_log_count() == 0
    end

    test "a plain moderator lacks :alias and is unauthorized" do
      tag = tag_fixture()

      assert Tags.reindex_tag_by_slug(actor(moderator_user_fixture()), tag.slug) ==
               {:error, :unauthorized}
    end

    test "anonymous and regular users are unauthorized" do
      tag = tag_fixture()

      assert Tags.reindex_tag_by_slug(actor(), tag.slug) == {:error, :unauthorized}

      assert Tags.reindex_tag_by_slug(actor(confirmed_user_fixture()), tag.slug) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is not-found for an admin, unauthorized otherwise" do
      assert Tags.reindex_tag_by_slug(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.reindex_tag_by_slug(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :unauthorized}
    end
  end

  describe "watch_tag/2 and unwatch_tag/2" do
    test "a signed-in user watches then unwatches a tag" do
      user = confirmed_user_fixture()
      tag = tag_fixture()

      assert {:ok, %Philomena.Users.User{} = watching} = Tags.watch_tag(actor(user), tag.slug)
      assert watching.watched_tag_ids == [tag.id]
      assert Repo.reload!(user).watched_tag_ids == [tag.id]

      assert {:ok, %Philomena.Users.User{}} = Tags.unwatch_tag(actor(watching), tag.slug)
      assert Repo.reload!(user).watched_tag_ids == []
    end

    test "unwatching a tag that is not watched is an idempotent success" do
      user = confirmed_user_fixture()
      tag = tag_fixture()

      assert {:ok, %Philomena.Users.User{}} = Tags.unwatch_tag(actor(user), tag.slug)
      assert Repo.reload!(user).watched_tag_ids == []
    end

    test "an unknown slug is not-found for both watch and unwatch" do
      user = confirmed_user_fixture()

      assert Tags.watch_tag(actor(user), "nonexistent-tag") == {:error, :not_found}
      assert Tags.unwatch_tag(actor(user), "nonexistent-tag") == {:error, :not_found}
    end
  end

  describe "create_tag/1 name length limit" do
    test "accepts a name of exactly the limit" do
      name = String.duplicate("a", @limit)

      assert {:ok, %Tag{name: ^name}} = Tags.create_tag(%{name: name})
    end

    test "rejects a name over the limit" do
      name = String.duplicate("a", @limit + 1)

      assert {:error, changeset} = Tags.create_tag(%{name: name})

      assert %{name: ["should be at most #{@limit} byte(s)"]} == errors_on(changeset)
    end

    test "counts bytes, not characters" do
      # 130 characters of "é" (2 bytes each in UTF-8) = 260 bytes
      name = String.duplicate("é", 130)

      assert {:error, changeset} = Tags.create_tag(%{name: name})
      assert %{name: [_message]} = errors_on(changeset)
    end
  end

  describe "parse_tag_list/1" do
    test "drops names over the limit and keeps the rest" do
      oversized = String.duplicate("a", @limit + 1)

      assert Tag.parse_tag_list("safe, #{oversized}, cute") == ["safe", "cute"]
    end

    test "keeps names of exactly the limit" do
      name = String.duplicate("a", @limit)

      assert Tag.parse_tag_list(name) == [name]
    end
  end

  describe "get_or_create_tags/1" do
    test "does not create tags with oversized names" do
      oversized = String.duplicate("a", @limit + 1)

      tags = Tags.get_or_create_tags("safe, #{oversized}")

      assert [%Tag{name: "safe"}] = tags
      assert Tags.get_tag_by_name(oversized) == nil
    end
  end
end
