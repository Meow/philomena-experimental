defmodule Philomena.NotificationsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.Notifications`
  functions.

  These pin the category route-parameter mapping (each recognized value and the
  unrecognized-value fallback to `:forum_post`) and the per-category grouping of
  a user's unread notifications.
  """

  use Philomena.DataCase, async: true

  alias Philomena.Channels
  alias Philomena.Notifications
  alias Philomena.Notifications.ChannelLiveNotification

  import Philomena.AttributionFixtures, only: [actor: 1]
  import Philomena.ChannelsFixtures
  import Philomena.UsersFixtures

  @pagination %{page_number: 1, page_size: 10}

  describe "category_for_param/1" do
    test "maps each recognized category parameter to its category" do
      assert Notifications.category_for_param("channel_live") == :channel_live
      assert Notifications.category_for_param("gallery_image") == :gallery_image
      assert Notifications.category_for_param("image_comment") == :image_comment
      assert Notifications.category_for_param("image_merge") == :image_merge
      assert Notifications.category_for_param("forum_topic") == :forum_topic
    end

    test "maps the forum_post parameter through the default clause" do
      assert Notifications.category_for_param("forum_post") == :forum_post
    end

    test "defaults any unrecognized value to forum_post" do
      # Preserved oddity: there is no clause for an unknown category, so the
      # catch-all maps everything unrecognized onto :forum_post.
      assert Notifications.category_for_param("bogus") == :forum_post
      assert Notifications.category_for_param("") == :forum_post
      assert Notifications.category_for_param(nil) == :forum_post
      assert Notifications.category_for_param(42) == :forum_post
    end
  end

  describe "unread_notifications_for_user/2" do
    test "returns every category keyed, each empty, when the user has none" do
      user = confirmed_user_fixture()

      result = Notifications.unread_notifications_for_user(actor(user), @pagination)

      assert Keyword.keys(result) == [
               :channel_live,
               :forum_post,
               :forum_topic,
               :gallery_image,
               :image_comment,
               :image_merge
             ]

      assert Enum.all?(result, fn {_category, page} -> page.entries == [] end)
    end

    test "groups an unread notification under its category" do
      user = confirmed_user_fixture()
      channel = channel_fixture()

      # Subscribe the user, then flag the channel live so a ChannelLiveNotification
      # lands for the subscriber.
      {:ok, _} = Channels.create_subscription(channel, user)
      assert {:ok, 1} = Notifications.create_channel_live_notification(channel)

      result = Notifications.unread_notifications_for_user(actor(user), @pagination)

      assert [%ChannelLiveNotification{}] = result[:channel_live].entries
      assert result[:forum_post].entries == []
      assert result[:image_comment].entries == []
    end

    test "does not surface another user's notifications" do
      subscriber = confirmed_user_fixture()
      other = confirmed_user_fixture()
      channel = channel_fixture()

      {:ok, _} = Channels.create_subscription(channel, subscriber)
      assert {:ok, 1} = Notifications.create_channel_live_notification(channel)

      result = Notifications.unread_notifications_for_user(actor(other), @pagination)

      assert result[:channel_live].entries == []
    end
  end
end
