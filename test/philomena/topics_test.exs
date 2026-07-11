defmodule Philomena.TopicsTest do
  @moduledoc """
  Context-level tests for the actor-first topic subscription API on
  `Philomena.Topics`: `subscribe/3` and `unsubscribe/3`.

  These pin the authorization matrix (anonymous / user / moderator / admin),
  the failure divergence between the two actions (unknown forum, unknown topic,
  hidden topic), and the idempotent success paths. The corresponding controller
  characterization tests pin the HTTP behavior on top of these results.

  The actor here is a plain `User.t()` or `nil`, matching what the controller
  hands in as `conn.assigns.current_user`.
  """

  use Philomena.DataCase, async: true

  import Ecto.Query

  import Philomena.ForumsFixtures
  import Philomena.TopicsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Repo
  alias Philomena.Topics
  alias Philomena.Topics.Subscription

  defp subscribed?(topic, user) do
    Repo.exists?(
      from s in Subscription,
        where: s.topic_id == ^topic.id and s.user_id == ^user.id
    )
  end

  defp subscription_count(topic, user) do
    Repo.aggregate(
      from(s in Subscription, where: s.topic_id == ^topic.id and s.user_id == ^user.id),
      :count
    )
  end

  # A visible topic in a normal (publicly readable) forum, the common case both
  # actions load through.
  defp visible_topic do
    forum = forum_fixture()
    topic = topic_fixture(forum)
    {forum, topic}
  end

  describe "subscribe/3" do
    test "a regular user subscribes to a visible topic and the row is created" do
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.subscribe(user, forum.short_name, topic.slug)

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id
      assert subscribed?(topic, user)
    end

    test "subscribing twice is idempotent and leaves a single row" do
      # create_subscription inserts with on_conflict: :nothing, so a repeat is a
      # successful no-op rather than a changeset error.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, _} = Topics.subscribe(user, forum.short_name, topic.slug)
      assert {:ok, _} = Topics.subscribe(user, forum.short_name, topic.slug)

      assert subscription_count(topic, user) == 1
    end

    test "a moderator subscribes to a visible topic" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, {_forum, _topic}} = Topics.subscribe(moderator, forum.short_name, topic.slug)
      assert subscribed?(topic, moderator)
    end

    test "an admin subscribes to a visible topic" do
      admin = admin_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, {_forum, _topic}} = Topics.subscribe(admin, forum.short_name, topic.slug)
      assert subscribed?(topic, admin)
    end

    test "an unknown forum slug is unauthorized for a regular user" do
      # The retired plug loaded the forum by short name and authorized the nil
      # result for :show, which no ordinary rule permits.
      assert Topics.subscribe(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :unauthorized}
    end

    test "an unknown forum slug is unauthorized for anonymous" do
      assert Topics.subscribe(nil, "nonexistent", "whatever") == {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic slug is not found" do
      forum = forum_fixture()

      assert Topics.subscribe(confirmed_user_fixture(), forum.short_name, "nonexistent-topic") ==
               {:error, :not_found}
    end

    test "a restricted forum is unauthorized for a regular user" do
      user = confirmed_user_fixture()
      forum = forum_fixture(access_level: "staff")
      topic = topic_fixture(forum)

      assert Topics.subscribe(user, forum.short_name, topic.slug) == {:error, :unauthorized}
      refute subscribed?(topic, user)
    end

    test "a restricted forum is subscribable by a moderator" do
      moderator = moderator_user_fixture()
      forum = forum_fixture(access_level: "staff")
      topic = topic_fixture(forum)

      assert {:ok, {_forum, _topic}} = Topics.subscribe(moderator, forum.short_name, topic.slug)
      assert subscribed?(topic, moderator)
    end

    test "a hidden topic is unauthorized for a regular user and no row is created" do
      # subscribe passes show_hidden: false, so a hidden topic falls to the
      # topic :show authorization, which a regular user fails.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()
      {:ok, topic} = Topics.hide_topic(topic, "test hiding", moderator_user_fixture())

      assert Topics.subscribe(user, forum.short_name, topic.slug) == {:error, :unauthorized}
      refute subscribed?(topic, user)
    end

    test "a hidden topic is subscribable by a moderator" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()
      {:ok, topic} = Topics.hide_topic(topic, "test hiding", moderator_user_fixture())

      assert {:ok, {_forum, _topic}} = Topics.subscribe(moderator, forum.short_name, topic.slug)
      assert subscribed?(topic, moderator)
    end

    test "anonymous reaching a visible topic crashes on the nil actor" do
      # NOTE: nothing in subscribe/3 denies anonymous for normal, visible
      # content; the only guard against it is the controller's
      # require_authenticated_user plug. At the context level a nil actor that
      # clears forum :show and topic visibility reaches create_subscription,
      # which dereferences actor.id and raises BadMapError.
      {forum, topic} = visible_topic()

      assert_raise BadMapError, ~r/expected a map, got:/, fn ->
        Topics.subscribe(nil, forum.short_name, topic.slug)
      end
    end

    test "an admin with an unknown forum crashes rather than reporting not found" do
      # NOTE: the admin blanket rule authorizes :show on the nil forum load, so
      # the divergence the other actors get (unauthorized) is skipped and the
      # subsequent topic query dereferences the nil forum, raising BadMapError.
      assert_raise BadMapError, ~r/expected a map, got:/, fn ->
        Topics.subscribe(admin_user_fixture(), "nonexistent", "whatever")
      end
    end
  end

  describe "unsubscribe/3" do
    test "a regular user unsubscribes from a visible topic and the row is removed" do
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()
      {:ok, _} = Topics.create_subscription(topic, user)
      assert subscribed?(topic, user)

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.unsubscribe(user, forum.short_name, topic.slug)

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id
      refute subscribed?(topic, user)
    end

    test "unsubscribing with no existing subscription still succeeds" do
      # delete_subscription runs an unconditional delete_all and hard-matches
      # {:ok, _}, so the absence of a row is not an error.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()
      refute subscribed?(topic, user)

      assert {:ok, {_forum, _topic}} = Topics.unsubscribe(user, forum.short_name, topic.slug)
      refute subscribed?(topic, user)
    end

    test "a moderator unsubscribes from a visible topic" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()
      {:ok, _} = Topics.create_subscription(topic, moderator)

      assert {:ok, {_forum, _topic}} = Topics.unsubscribe(moderator, forum.short_name, topic.slug)
      refute subscribed?(topic, moderator)
    end

    test "a hidden topic can still be unsubscribed from by a regular user" do
      # unsubscribe passes show_hidden: true, so a topic hidden after the user
      # subscribed stays reachable for removal.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()
      {:ok, _} = Topics.create_subscription(topic, user)
      {:ok, topic} = Topics.hide_topic(topic, "test hiding", moderator_user_fixture())

      assert {:ok, {_forum, _topic}} = Topics.unsubscribe(user, forum.short_name, topic.slug)
      refute subscribed?(topic, user)
    end

    test "an unknown forum slug is unauthorized for a regular user" do
      assert Topics.unsubscribe(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic slug is not found" do
      forum = forum_fixture()

      assert Topics.unsubscribe(confirmed_user_fixture(), forum.short_name, "nonexistent-topic") ==
               {:error, :not_found}
    end

    test "a restricted forum is unauthorized for a regular user" do
      user = confirmed_user_fixture()
      forum = forum_fixture(access_level: "staff")
      topic = topic_fixture(forum)

      assert Topics.unsubscribe(user, forum.short_name, topic.slug) == {:error, :unauthorized}
    end
  end
end
