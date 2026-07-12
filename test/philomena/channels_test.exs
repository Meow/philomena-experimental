defmodule Philomena.ChannelsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.Channels` functions:
  the livestreams index, the visit/notification/subscription actions, and the
  staff-only CRUD form loaders and writes.

  These pin the fetched-only index scoping with its NSFW filter and `cq` search,
  the per-role authorization matrices (the `:show` actions any visitor may
  reach, the `:new`/`:create`/`:edit`/`:update`/`:delete` actions restricted to
  moderators and up), the non-castable/unknown id split (unknown well-formed id
  unauthorized for a non-admin, not-found for an admin), and the preserved
  oddity that an update ignores the fetcher-managed fields.

  The read/subscription actor is a plain `User.t()` or `nil`, matching what the
  controller hands in as `conn.assigns.current_user`; the CRUD form loaders take
  a `%User{}` only.
  """

  use Philomena.DataCase, async: true

  alias Philomena.Channels
  alias Philomena.Channels.Channel
  alias Philomena.Repo

  import Philomena.ChannelsFixtures
  import Philomena.TagsFixtures
  import Philomena.UsersFixtures

  @pagination %{page_number: 1, page_size: 25}

  describe "list_channels/3" do
    test "lists only channels the fetcher has stamped" do
      fetched = listed_channel_fixture()
      unfetched = channel_fixture()

      page = Channels.list_channels(true, %{}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert fetched.id in ids
      refute unfetched.id in ids
    end

    test "excludes NSFW channels when NSFW is not shown" do
      sfw = listed_channel_fixture(%{}, %{nsfw: false})
      nsfw = listed_channel_fixture(%{}, %{nsfw: true})

      page = Channels.list_channels(false, %{}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert sfw.id in ids
      refute nsfw.id in ids
    end

    test "includes NSFW channels when NSFW is shown" do
      nsfw = listed_channel_fixture(%{}, %{nsfw: true})

      page = Channels.list_channels(true, %{}, @pagination)

      assert nsfw.id in Enum.map(page.entries, & &1.id)
    end

    test "orders live channels ahead of offline ones" do
      offline = listed_channel_fixture(%{}, %{is_live: false, title: "zzz offline"})
      live = listed_channel_fixture(%{}, %{is_live: true, title: "aaa live"})

      page = Channels.list_channels(true, %{}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert Enum.find_index(ids, &(&1 == live.id)) <
               Enum.find_index(ids, &(&1 == offline.id))
    end

    test "a cq matches the channel title by prefix" do
      match = listed_channel_fixture(%{}, %{title: "Pony Stream"})
      other = listed_channel_fixture(%{}, %{title: "Cat Stream"})

      page = Channels.list_channels(true, %{"cq" => "Pony"}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert match.id in ids
      refute other.id in ids
    end

    test "a cq matches the channel short name by prefix" do
      match = listed_channel_fixture(%{"short_name" => "searchablechan"})
      other = listed_channel_fixture()

      page = Channels.list_channels(true, %{"cq" => "searchable"}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert match.id in ids
      refute other.id in ids
    end

    test "a cq matches the associated artist tag name by substring" do
      tag = tag_fixture(%{name: "artist:cqsearchtarget"})
      match = listed_channel_fixture(%{"artist_tag" => tag.name})
      other = listed_channel_fixture()

      page = Channels.list_channels(true, %{"cq" => "cqsearchtarget"}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert match.id in ids
      refute other.id in ids
    end

    test "the associated artist tag is preloaded" do
      tag = tag_fixture(%{name: "artist:preloadtag"})
      listed_channel_fixture(%{"artist_tag" => tag.name})

      page = Channels.list_channels(true, %{}, @pagination)
      [channel | _] = page.entries

      assert Ecto.assoc_loaded?(channel.associated_artist_tag)
    end
  end

  describe "visit_channel/2" do
    test "an anonymous visitor visits a channel" do
      channel = channel_fixture()

      assert {:ok, loaded} = Channels.visit_channel(nil, to_string(channel.id))
      assert loaded.id == channel.id
    end

    test "a signed-in user visits a channel" do
      channel = channel_fixture()

      assert {:ok, loaded} =
               Channels.visit_channel(confirmed_user_fixture(), to_string(channel.id))

      assert loaded.id == channel.id
    end

    test "an unknown well-formed id is unauthorized for an anonymous visitor" do
      # No :show rule matches the nil load, so a missing channel surfaces as
      # unauthorized rather than not found.
      assert Channels.visit_channel(nil, "2147483647") == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a regular user" do
      assert Channels.visit_channel(confirmed_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      assert Channels.visit_channel(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not found" do
      assert Channels.visit_channel(nil, "not-an-integer") == {:error, :not_found}
    end
  end

  describe "clear_notification/2" do
    test "a signed-in user clears the notification and gets the channel back" do
      channel = channel_fixture()

      assert {:ok, loaded} =
               Channels.clear_notification(confirmed_user_fixture(), to_string(channel.id))

      assert loaded.id == channel.id
    end

    test "an unknown well-formed id is not found, with no authorization involved" do
      assert Channels.clear_notification(confirmed_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-integer id is not found" do
      assert Channels.clear_notification(confirmed_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end
  end

  describe "new_channel/1" do
    test "a regular user is unauthorized" do
      assert Channels.new_channel(confirmed_user_fixture()) == {:error, :unauthorized}
    end

    test "a moderator gets a blank changeset" do
      assert {:ok, %Ecto.Changeset{data: %Channel{id: nil}}} =
               Channels.new_channel(moderator_user_fixture())
    end

    test "an admin gets a blank changeset" do
      assert {:ok, %Ecto.Changeset{}} = Channels.new_channel(admin_user_fixture())
    end
  end

  describe "create_channel/2" do
    test "a regular user is unauthorized" do
      assert Channels.create_channel(confirmed_user_fixture(), %{
               "type" => "PicartoChannel",
               "short_name" => unique_channel_short_name()
             }) == {:error, :unauthorized}
    end

    test "a moderator creates a channel" do
      assert {:ok, %Channel{} = channel} =
               Channels.create_channel(moderator_user_fixture(), %{
                 "type" => "PicartoChannel",
                 "short_name" => unique_channel_short_name()
               })

      assert channel.type == "PicartoChannel"
    end

    test "an invalid type is a rejected changeset" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Channels.create_channel(moderator_user_fixture(), %{
                 "type" => "NotARealChannel",
                 "short_name" => unique_channel_short_name()
               })

      refute changeset.valid?
    end

    test "the artist tag is resolved from the attributes" do
      tag = tag_fixture(%{name: "artist:createwithtag"})

      assert {:ok, %Channel{} = channel} =
               Channels.create_channel(moderator_user_fixture(), %{
                 "type" => "PicartoChannel",
                 "short_name" => unique_channel_short_name(),
                 "artist_tag" => tag.name
               })

      assert channel.associated_artist_tag_id == tag.id
    end
  end

  describe "load_channel_for_edit/2" do
    test "a moderator loads a channel paired with an edit changeset" do
      channel = channel_fixture()

      assert {:ok, {%Channel{} = loaded, %Ecto.Changeset{} = changeset}} =
               Channels.load_channel_for_edit(moderator_user_fixture(), to_string(channel.id))

      assert loaded.id == channel.id
      assert changeset.data.id == channel.id
    end

    test "a regular user is unauthorized" do
      channel = channel_fixture()

      assert Channels.load_channel_for_edit(confirmed_user_fixture(), to_string(channel.id)) ==
               {:error, :unauthorized}
    end

    test "a non-integer id is not found" do
      assert Channels.load_channel_for_edit(moderator_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not found for an admin" do
      assert Channels.load_channel_for_edit(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Channels.load_channel_for_edit(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "update_channel/3" do
    test "a moderator renames a channel" do
      channel = channel_fixture()
      new_name = unique_channel_short_name()

      assert {:ok, %Channel{} = updated} =
               Channels.update_channel(moderator_user_fixture(), to_string(channel.id), %{
                 "short_name" => new_name
               })

      assert updated.short_name == new_name
      assert Repo.reload!(channel).short_name == new_name
    end

    test "an update silently ignores fetcher-managed fields" do
      # Channel.changeset/2 casts only :type and :short_name, so a crafted update
      # carrying a fetcher-managed field like :title succeeds but leaves it
      # unchanged.
      channel = listed_channel_fixture(%{}, %{title: "Original Title"})

      assert {:ok, %Channel{} = updated} =
               Channels.update_channel(moderator_user_fixture(), to_string(channel.id), %{
                 "title" => "Crafted Title"
               })

      assert updated.title == "Original Title"
      assert Repo.reload!(channel).title == "Original Title"
    end

    test "an invalid type is a rejected changeset" do
      channel = channel_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Channels.update_channel(moderator_user_fixture(), to_string(channel.id), %{
                 "type" => "NotARealChannel"
               })

      refute changeset.valid?
    end

    test "a regular user is unauthorized and leaves the row unchanged" do
      channel = channel_fixture()

      assert Channels.update_channel(confirmed_user_fixture(), to_string(channel.id), %{
               "short_name" => "hijacked"
             }) == {:error, :unauthorized}

      assert Repo.reload!(channel).short_name == channel.short_name
    end

    test "a non-integer id is not found" do
      assert Channels.update_channel(moderator_user_fixture(), "not-an-integer", %{
               "short_name" => "x"
             }) == {:error, :not_found}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not found for an admin" do
      assert Channels.update_channel(moderator_user_fixture(), "2147483647", %{
               "short_name" => "x"
             }) == {:error, :unauthorized}

      assert Channels.update_channel(admin_user_fixture(), "2147483647", %{"short_name" => "x"}) ==
               {:error, :not_found}
    end
  end

  describe "delete_channel/2" do
    test "a moderator deletes a channel" do
      channel = channel_fixture()

      assert {:ok, %Channel{}} =
               Channels.delete_channel(moderator_user_fixture(), to_string(channel.id))

      assert Repo.reload(channel) == nil
    end

    test "a regular user is unauthorized and leaves the row" do
      channel = channel_fixture()

      assert Channels.delete_channel(confirmed_user_fixture(), to_string(channel.id)) ==
               {:error, :unauthorized}

      refute Repo.reload(channel) == nil
    end

    test "a non-integer id is not found" do
      assert Channels.delete_channel(moderator_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not found for an admin" do
      assert Channels.delete_channel(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Channels.delete_channel(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end
  end

  describe "subscribe/2 and unsubscribe/2" do
    test "a user subscribes to and then unsubscribes from a channel" do
      user = confirmed_user_fixture()
      channel = channel_fixture()

      assert {:ok, subscribed} = Channels.subscribe(user, to_string(channel.id))
      assert subscribed.id == channel.id
      assert Channels.subscribed?(channel, user)

      assert {:ok, unsubscribed} = Channels.unsubscribe(user, to_string(channel.id))
      assert unsubscribed.id == channel.id
      refute Channels.subscribed?(channel, user)
    end

    test "subscribing is idempotent" do
      user = confirmed_user_fixture()
      channel = channel_fixture()

      assert {:ok, _} = Channels.subscribe(user, to_string(channel.id))
      assert {:ok, _} = Channels.subscribe(user, to_string(channel.id))
      assert Channels.subscribed?(channel, user)
    end

    test "unsubscribing when not subscribed is an idempotent success" do
      user = confirmed_user_fixture()
      channel = channel_fixture()

      assert {:ok, loaded} = Channels.unsubscribe(user, to_string(channel.id))
      assert loaded.id == channel.id
    end

    test "an unknown well-formed id is unauthorized for a user, not found for an admin" do
      assert Channels.subscribe(confirmed_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Channels.subscribe(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not found on subscribe" do
      assert Channels.subscribe(confirmed_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end

    test "an unknown well-formed id is unauthorized for a user on unsubscribe" do
      assert Channels.unsubscribe(confirmed_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Channels.unsubscribe(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end
  end
end
