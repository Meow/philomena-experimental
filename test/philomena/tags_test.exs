defmodule Philomena.TagsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.Tags` functions and
  their typed page, detail, and search-form results.

  These pin the per-role authorization matrices on the edit/alias/delete/image
  paths, load-before-authorize not-found behavior, the byte-exact moderation
  logs the write paths emit, and the two search-backed loaders.
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.AttributionFixtures, only: [actor: 0, actor: 1, actor: 2]
  import Philomena.FiltersFixtures
  import Philomena.ImagesFixtures
  import Philomena.TagsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Tags
  alias Philomena.Tags.QueryForm
  alias Philomena.Tags.Tag
  alias Philomena.Tags.TagDetail
  alias Philomena.Tags.TagPage
  alias Philomena.Images.Image
  alias Philomena.Images.Search.Scope
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Repo
  alias Philomena.Multi
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

  defp scope(_user) do
    Scope.new(default_filter(), @pagination)
  end

  defp only_moderation_log!, do: Repo.one!(ModerationLog)

  defp moderation_log_count, do: Repo.aggregate(ModerationLog, :count)

  describe "search_tags/3" do
    test "finds an indexed tag by a wildcard query, carrying the default preloads" do
      tag = tag_fixture()
      SearchHelpers.reindex_all!(Tag)

      assert {:ok, tags, %Ecto.Changeset{data: %QueryForm{query: "*"}}} =
               Tags.search_tags(actor(), %{"query" => "*"}, @pagination)

      assert %Tag{} = found = Enum.find(tags, &(&1.id == tag.id))
      assert Ecto.assoc_loaded?(found.aliases)
      assert Ecto.assoc_loaded?(found.dnp_entries)
    end

    test "a missing query compiles to match-none, returning an empty page" do
      tag_fixture()
      SearchHelpers.reindex_all!(Tag)

      assert {:ok, tags, %Ecto.Changeset{data: %QueryForm{query: nil}}} =
               Tags.search_tags(actor(), %{"query" => nil}, @pagination)

      assert Enum.empty?(tags)
    end

    test "the caller owns pagination and results always carry representation preloads" do
      tag = tag_fixture()
      SearchHelpers.reindex_all!(Tag)

      pagination = %{@pagination | page_size: 250}

      assert {:ok, tags, %Ecto.Changeset{}} =
               Tags.search_tags(actor(), %{"query" => "*"}, pagination)

      assert tags.page_size == 250
      assert %Tag{} = found = Enum.find(tags, &(&1.id == tag.id))
      assert Ecto.assoc_loaded?(found.aliases)
    end

    test "a malformed query returns the rejected query form" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Tags.search_tags(actor(), %{"query" => "("}, @pagination)

      assert %{query: [message]} = errors_on(changeset)
      assert is_binary(message)
    end
  end

  describe "load_tag_page/2" do
    test "assembles the page for a real tag, carrying its tagged image" do
      created_at = DateTime.utc_now() |> DateTime.add(-3600) |> DateTime.truncate(:second)
      image = image_fixture(tags: "safe", created_at: created_at)
      tag = Tags.find_canonical_tag_by_name("safe")
      SearchHelpers.reindex_all!(Image)

      assert {:ok, %TagPage{} = page} = Tags.load_tag_page(actor(), scope(nil), tag.slug)

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

      assert {:aliased_to, %Tag{} = returned} =
               Tags.load_tag_page(actor(), scope(nil), aliased.slug)

      assert returned.id == aliased.id
      assert returned.aliased_tag.id == target.id
    end

    test "an unknown slug is not-found for every viewer" do
      assert Tags.load_tag_page(actor(), scope(nil), "nonexistent-tag") ==
               {:error, :not_found}

      user = confirmed_user_fixture()

      assert Tags.load_tag_page(actor(user), scope(user), "nonexistent-tag") ==
               {:error, :not_found}

      moderator = moderator_user_fixture()

      assert Tags.load_tag_page(actor(moderator), scope(moderator), "nonexistent-tag") ==
               {:error, :not_found}
    end
  end

  describe "load_tag/2 and load_canonical_tag/2" do
    test "the representation loader preserves an alias while the canonical loader resolves it" do
      target = tag_fixture(name: "canonical target")

      aliased =
        tag_fixture(name: "canonical alias")
        |> Ecto.Changeset.change(aliased_tag_id: target.id)
        |> Repo.update!()

      assert {:ok, %Tag{id: alias_id, aliased_tag: %Tag{id: target_id}}} =
               Tags.load_tag(actor(), aliased.slug)

      assert alias_id == aliased.id
      assert target_id == target.id

      assert {:ok, %Tag{id: canonical_id}} = Tags.load_canonical_tag(actor(), aliased.slug)
      assert canonical_id == target.id
    end

    test "missing and malformed locators are not found" do
      assert Tags.load_tag(actor(), "missing") == {:error, :not_found}
      assert Tags.load_tag(actor(), nil) == {:error, :not_found}
      assert Tags.load_canonical_tag(actor(), nil) == {:error, :not_found}
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

    test "an unknown slug is not-found before authorization" do
      assert Tags.load_tag_for_edit(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.load_tag_for_edit(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
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

    test "an unknown slug is not-found before authorization" do
      assert Tags.update_tag(actor(admin_user_fixture()), "nonexistent-tag", %{
               "category" => "rating"
             }) ==
               {:error, :not_found}

      assert Tags.update_tag(actor(moderator_user_fixture()), "nonexistent-tag", %{
               "category" => "rating"
             }) == {:error, :not_found}
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

    test "an unknown slug is not-found before authorization" do
      assert Tags.delete_tag(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.delete_tag(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
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

    test "an unknown slug is not-found before authorization" do
      assert Tags.load_tag_alias_for_edit(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.load_tag_alias_for_edit(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
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

    test "accepts atom-keyed form attributes" do
      target = tag_fixture(name: "atom alias target")
      tag = tag_fixture(name: "atom alias source")

      assert {:ok, %Tag{aliased_tag_id: target_id}} =
               Tags.alias_tag(actor(admin_user_fixture()), tag.slug, %{target_tag: target.name})

      assert target_id == target.id
    end

    test "rejects self-aliases and tags that already have incoming aliases" do
      admin = actor(admin_user_fixture())
      tag = tag_fixture(name: "alias conflict source")

      assert {:error, self_changeset} =
               Tags.alias_tag(admin, tag.slug, %{"target_tag" => tag.name})

      assert %{aliased_tag: [_message]} = errors_on(self_changeset)

      _incoming =
        tag_fixture(name: "incoming alias")
        |> Ecto.Changeset.change(aliased_tag_id: tag.id)
        |> Repo.update!()

      target = tag_fixture(name: "alias conflict target")

      assert {:error, incoming_changeset} =
               Tags.alias_tag(admin, tag.slug, %{"target_tag" => target.name})

      assert %{tag: [_message]} = errors_on(incoming_changeset)
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

    test "an unknown slug is not-found before authorization" do
      assert Tags.alias_tag(actor(admin_user_fixture()), "nonexistent-tag", %{"target_tag" => "x"}) ==
               {:error, :not_found}

      assert Tags.alias_tag(actor(moderator_user_fixture()), "nonexistent-tag", %{
               "target_tag" => "x"
             }) ==
               {:error, :not_found}
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

    test "a tag that is not aliased is rejected before audit or queueing" do
      tag = tag_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tags.unalias_tag(actor(admin_user_fixture()), tag.slug)

      assert %{aliased_tag: ["is not aliased"]} = errors_on(changeset)
      assert moderation_log_count() == 0
    end

    test "an unknown slug is not-found before authorization" do
      assert Tags.unalias_tag(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.unalias_tag(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
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

      assert {:ok, %TagDetail{} = detail} =
               Tags.tag_detail(actor(moderator_user_fixture()), tag.slug)

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

    test "an unknown slug is not-found before authorization" do
      assert Tags.tag_detail(actor(), "nonexistent-tag") == {:error, :not_found}

      assert Tags.tag_detail(actor(confirmed_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.tag_detail(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
    end
  end

  describe "load_tag_image_for_edit/2" do
    test "loads only the spoiler-image form dependencies" do
      tag = tag_fixture()

      assert {:ok, {%Tag{} = loaded, %Ecto.Changeset{}}} =
               Tags.load_tag_image_for_edit(actor(moderator_user_fixture()), tag.slug)

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

    test "an unknown slug is not-found before authorization" do
      assert Tags.update_tag_image(actor(admin_user_fixture()), "nonexistent-tag", %{
               "image" => png_upload()
             }) == {:error, :not_found}

      assert Tags.update_tag_image(actor(moderator_user_fixture()), "nonexistent-tag", %{
               "image" => png_upload()
             }) == {:error, :not_found}
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

    test "an unknown slug is not-found before authorization" do
      assert Tags.remove_tag_image(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.remove_tag_image(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
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

    test "an unknown slug is not-found before authorization" do
      assert Tags.reindex_tag_by_slug(actor(admin_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}

      assert Tags.reindex_tag_by_slug(actor(moderator_user_fixture()), "nonexistent-tag") ==
               {:error, :not_found}
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

  describe "write access parity" do
    test "form loaders and their matching mutations reject a banned staff actor" do
      admin = admin_user_fixture()
      banned_actor = actor(admin, ban: %{})
      tag = tag_fixture(name: "banned tag source")
      target = tag_fixture(name: "banned tag target")

      assert Tags.load_tag_for_edit(banned_actor, tag.slug) == {:error, :ban}
      assert Tags.load_tag_image_for_edit(banned_actor, tag.slug) == {:error, :ban}
      assert Tags.load_tag_alias_for_edit(banned_actor, tag.slug) == {:error, :ban}

      assert Tags.update_tag(banned_actor, tag.slug, %{}) == {:error, :ban}
      assert Tags.update_tag_image(banned_actor, tag.slug, %{}) == {:error, :ban}
      assert Tags.remove_tag_image(banned_actor, tag.slug) == {:error, :ban}

      assert Tags.alias_tag(banned_actor, tag.slug, %{"target_tag" => target.name}) ==
               {:error, :ban}

      assert Tags.unalias_tag(banned_actor, tag.slug) == {:error, :ban}
      assert Tags.reindex_tag_by_slug(banned_actor, tag.slug) == {:error, :ban}
      assert Tags.delete_tag(banned_actor, tag.slug) == {:error, :ban}
      assert moderation_log_count() == 0
    end
  end

  describe "put_copy_tags/3" do
    test "copies only missing integer tag ids and increments their counters exactly once" do
      source = image_fixture(tags: "copy shared, copy source only")
      target = image_fixture(tags: "copy shared")

      shared =
        "copy shared"
        |> Tags.find_canonical_tag_by_name()
        |> Ecto.Changeset.change(images_count: 2)
        |> Repo.update!()

      source_only =
        "copy source only"
        |> Tags.find_canonical_tag_by_name()
        |> Ecto.Changeset.change(images_count: 1)
        |> Repo.update!()

      assert {:ok, %{copied_tag_ids: [copied_id]}} =
               Multi.new()
               |> Tags.put_copy_tags(source, target)
               |> Multi.transact()

      assert copied_id == source_only.id
      assert Repo.reload!(shared).images_count == 2
      assert Repo.reload!(source_only).images_count == 2

      target_tag_ids =
        target
        |> Repo.preload(:tags, force: true)
        |> Map.fetch!(:tags)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert target_tag_ids == Enum.sort([shared.id, source_only.id])
    end
  end

  describe "cleanup!/0" do
    test "deletes eligible tags once, returns their ids, and preserves meaningful tags" do
      empty = tag_fixture(name: "cleanup empty")

      kept =
        tag_fixture(name: "cleanup described")
        |> Ecto.Changeset.change(description: "Still useful")
        |> Repo.update!()

      assert {1, [empty_id]} = Tags.cleanup!()
      assert empty_id == empty.id
      refute Repo.get(Tag, empty.id)
      assert Repo.get(Tag, kept.id)
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
      assert Tags.find_canonical_tag_by_name(oversized) == nil
    end
  end
end
