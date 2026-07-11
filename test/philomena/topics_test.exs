defmodule Philomena.TopicsTest do
  @moduledoc """
  Context-level tests for the actor-first topic APIs on `Philomena.Topics`:
  `subscribe/3`, `unsubscribe/3`, and `mark_topic_read/3`.

  These pin the authorization matrix (anonymous / user / moderator / admin),
  the failure divergence between the two actions (unknown forum, unknown topic,
  hidden topic), and the idempotent success paths. The corresponding controller
  characterization tests pin the HTTP behavior on top of these results.

  The actor here is a plain `User.t()` or `nil`, matching what the controller
  hands in as `conn.assigns.current_user`.
  """

  use Philomena.DataCase, async: true

  import Ecto.Query

  import Philomena.AttributionFixtures
  import Philomena.ForumsFixtures
  import Philomena.PostsFixtures
  import Philomena.TopicsFixtures
  import Philomena.UsersFixtures

  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Notifications
  alias Philomena.Notifications.ForumPostNotification
  alias Philomena.Posts.Post
  alias Philomena.Repo
  alias Philomena.Topics
  alias Philomena.Topics.Subscription
  alias Philomena.Topics.Topic
  alias Philomena.Topics.TopicPage

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to verify_write_access
  # and verify_not_banned.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  # The request pagination map load_topic_page reads: only :page_number is used.
  @first_page %{page_number: 1}

  defp subscribed?(topic, user) do
    Repo.exists?(
      from s in Subscription,
        where: s.topic_id == ^topic.id and s.user_id == ^user.id
    )
  end

  defp post_notification?(topic, user) do
    Repo.exists?(
      from n in ForumPostNotification,
        where: n.topic_id == ^topic.id and n.user_id == ^user.id
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

  # A hidden topic in a normal forum, the shape unhide_topic/3 operates on. The
  # internal hide engine writes no moderation log, so a later log assertion sees
  # only the row unhide_topic/3 itself creates.
  defp hidden_topic do
    forum = forum_fixture()
    topic = topic_fixture(forum)
    {:ok, hidden} = Topics.hide_topic(topic, "Spam", moderator_user_fixture())
    {forum, hidden}
  end

  # A locked topic in a normal forum, the shape unlock_topic/3 operates on.
  # Locking (unlike hiding) leaves the topic visible, so the loader still admits
  # a regular user. The internal lock engine writes no moderation log, so a later
  # log assertion sees only the row unlock_topic/3 itself creates.
  defp locked_topic do
    forum = forum_fixture()
    topic = topic_fixture(forum)

    {:ok, locked} =
      Topics.lock_topic(topic, %{"lock_reason" => "Off topic"}, moderator_user_fixture())

    {forum, locked}
  end

  # A sticky topic in a normal forum, the shape unstick_topic/3 operates on.
  # Sticking (like locking) leaves the topic visible, so the loader still admits
  # a regular user. The internal stick engine writes no moderation log, so a
  # later log assertion sees only the row unstick_topic/3 itself creates.
  defp sticky_topic do
    forum = forum_fixture()
    topic = topic_fixture(forum)
    {:ok, sticky} = Topics.stick_topic(topic)
    {forum, sticky}
  end

  defp only_moderation_log!, do: Repo.one!(ModerationLog)

  defp moderation_log_count, do: Repo.aggregate(ModerationLog, :count)

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
      # An unknown short name loads nil, and authorizing nil for :show is
      # unauthorized for every non-admin actor.
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

  describe "mark_topic_read/3" do
    test "an unknown forum slug is not found for a regular user" do
      # Divergence from subscribe/3: the read path loads the forum with a plain
      # required load and no authorization, so a missing forum is :not_found
      # rather than the :unauthorized that subscribe returns for a regular user.
      assert Topics.mark_topic_read(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :not_found}
    end

    test "an unknown forum slug is not found for anonymous" do
      assert Topics.mark_topic_read(nil, "nonexistent", "whatever") == {:error, :not_found}
    end

    test "an existing forum with an unknown topic slug is not found" do
      forum = forum_fixture()

      assert Topics.mark_topic_read(
               confirmed_user_fixture(),
               forum.short_name,
               "nonexistent-topic"
             ) ==
               {:error, :not_found}
    end

    test "a hidden topic is marked read by a regular user with no visibility gate" do
      # The read path loads the topic with show_hidden: true and runs no :show
      # authorization, so a regular user reaches a hidden topic that subscribe/3
      # would refuse with :unauthorized.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()
      {:ok, topic} = Topics.hide_topic(topic, "test hiding", moderator_user_fixture())

      assert {:ok, loaded_topic} = Topics.mark_topic_read(user, forum.short_name, topic.slug)
      assert loaded_topic.id == topic.id
    end

    test "a staff-only forum is marked read by a regular user with no forum authorization" do
      # The read path performs no forum :show authorization, so a forum a regular
      # user cannot see is still markable, unlike subscribe/3 which returns
      # :unauthorized here.
      user = confirmed_user_fixture()
      forum = forum_fixture(access_level: "staff")
      topic = topic_fixture(forum)

      assert {:ok, loaded_topic} = Topics.mark_topic_read(user, forum.short_name, topic.slug)
      assert loaded_topic.id == topic.id
    end

    test "success clears the topic notification for the user" do
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      # Arrange a real unread notification the way the read controller test does:
      # subscribe the user to the topic, then have another user post so a
      # ForumPostNotification lands for the subscriber.
      {:ok, _} = Topics.create_subscription(topic, user)
      author = confirmed_user_fixture()
      post = hd(topic.posts)
      {:ok, 1} = Notifications.create_forum_post_notification(author, topic, post)
      assert post_notification?(topic, user)

      assert {:ok, _topic} = Topics.mark_topic_read(user, forum.short_name, topic.slug)
      refute post_notification?(topic, user)
    end

    test "marking read is safe when the user has no notifications" do
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()
      refute post_notification?(topic, user)

      assert {:ok, loaded_topic} = Topics.mark_topic_read(user, forum.short_name, topic.slug)
      assert loaded_topic.id == topic.id
    end

    test "a nil actor marks read harmlessly and returns the topic" do
      # clear_topic_notification/2 forwards nil to delete_all_for_user, which
      # short-circuits to {:ok, 0} for a nil user, so an anonymous actor reaching
      # a visible topic is a successful no-op rather than a crash (contrast
      # subscribe/3, where a nil actor raises BadMapError in create_subscription).
      {forum, topic} = visible_topic()

      assert {:ok, loaded_topic} = Topics.mark_topic_read(nil, forum.short_name, topic.slug)
      assert loaded_topic.id == topic.id
    end
  end

  describe "hide_topic/4" do
    test "a regular user cannot hide a visible topic and the topic stays visible" do
      # The visibility loader clears a regular user on a normal, visible topic;
      # the block on the topic :hide permission is what denies the action.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      assert Topics.hide_topic(user, forum.short_name, topic.slug, "Spam") ==
               {:error, :unauthorized}

      refute Repo.reload!(topic).hidden_from_users
    end

    test "an anonymous actor cannot hide a visible topic" do
      # nil clears forum :show and topic visibility on normal content, but fails
      # the topic :hide permission, so this is a clean unauthorized rather than a
      # crash on the nil actor.
      {forum, topic} = visible_topic()

      assert Topics.hide_topic(nil, forum.short_name, topic.slug, "Spam") ==
               {:error, :unauthorized}

      refute Repo.reload!(topic).hidden_from_users
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Topics.hide_topic(confirmed_user_fixture(), "nonexistent", "whatever", "Spam") ==
               {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.hide_topic(
               moderator_user_fixture(),
               forum.short_name,
               "nonexistent-topic",
               "Spam"
             ) ==
               {:error, :not_found}
    end

    test "a moderator hides the topic, setting the flag, reason, and deleter" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.hide_topic(moderator, forum.short_name, topic.slug, "Rule violation")

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id

      hidden = Repo.reload!(topic)
      assert hidden.hidden_from_users
      assert hidden.deletion_reason == "Rule violation"
      assert hidden.deleted_by_id == moderator.id
    end

    test "a successful hide writes a byte-exact moderation log" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, _} =
               Topics.hide_topic(moderator, forum.short_name, topic.slug, "Rule violation")

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Topic.Hide:create"
      assert log.subject_path == "/forums/#{forum.short_name}/topics/#{topic.slug}"
      assert log.body == "Deleted topic '#{topic.title}' (Rule violation) in #{forum.name}"
    end

    test "a blank or nil reason yields the 3-tuple error and writes no moderation log" do
      # hide_changeset requires deletion_reason; hide_topic/4 surfaces the
      # normalized changeset failure as {:error, forum, topic} (both the loaded
      # forum and the pre-update topic) so the controller can still redirect.
      moderator = moderator_user_fixture()

      {forum, topic} = visible_topic()

      assert {:error, blank_forum, blank_topic} =
               Topics.hide_topic(moderator, forum.short_name, topic.slug, "")

      assert blank_forum.id == forum.id
      assert blank_topic.id == topic.id

      {nil_forum, nil_topic} = visible_topic()

      assert {:error, error_forum, error_topic} =
               Topics.hide_topic(moderator, nil_forum.short_name, nil_topic.slug, nil)

      assert error_forum.id == nil_forum.id
      assert error_topic.id == nil_topic.id

      refute Repo.reload!(topic).hidden_from_users
      refute Repo.reload!(nil_topic).hidden_from_users
      assert moderation_log_count() == 0
    end
  end

  describe "unhide_topic/3" do
    test "a regular user cannot reach a hidden topic through the visibility loader" do
      # unhide_topic/3 loads with show_hidden: false, so a hidden topic falls to
      # the topic :show check, which a regular user fails before :hide is even
      # considered.
      user = confirmed_user_fixture()
      {forum, topic} = hidden_topic()

      assert Topics.unhide_topic(user, forum.short_name, topic.slug) == {:error, :unauthorized}
      assert Repo.reload!(topic).hidden_from_users
    end

    test "an anonymous actor cannot reach a hidden topic" do
      {forum, topic} = hidden_topic()

      assert Topics.unhide_topic(nil, forum.short_name, topic.slug) == {:error, :unauthorized}
      assert Repo.reload!(topic).hidden_from_users
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Topics.unhide_topic(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.unhide_topic(moderator_user_fixture(), forum.short_name, "nonexistent-topic") ==
               {:error, :not_found}
    end

    test "a moderator restores a hidden topic, clearing the flag, reason, and deleter" do
      # Even though the loader passes show_hidden: false, a moderator may :show a
      # hidden topic, so the visibility loader admits it and :hide then permits
      # the restore; the moderator reaches and unhides the topic.
      moderator = moderator_user_fixture()
      {forum, topic} = hidden_topic()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.unhide_topic(moderator, forum.short_name, topic.slug)

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id

      restored = Repo.reload!(topic)
      refute restored.hidden_from_users
      assert restored.deletion_reason == ""
      assert restored.deleted_by_id == nil
    end

    test "a successful restore writes a byte-exact moderation log" do
      moderator = moderator_user_fixture()
      {forum, topic} = hidden_topic()

      assert {:ok, _} = Topics.unhide_topic(moderator, forum.short_name, topic.slug)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Topic.Hide:delete"
      assert log.subject_path == "/forums/#{forum.short_name}/topics/#{topic.slug}"
      assert log.body == "Restored topic '#{topic.title}' in #{forum.name}"
    end
  end

  describe "lock_topic/4" do
    test "a regular user cannot lock a visible topic and the topic stays unlocked" do
      # The visibility loader clears a regular user on a normal, visible topic;
      # the block on the topic :hide permission is what denies the lock.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      assert Topics.lock_topic(user, forum.short_name, topic.slug, %{"lock_reason" => "Off topic"}) ==
               {:error, :unauthorized}

      assert Repo.reload!(topic).locked_at == nil
    end

    test "an anonymous actor cannot lock a visible topic" do
      # nil clears forum :show and topic visibility on normal content, but fails
      # the topic :hide permission, so this is a clean unauthorized rather than a
      # crash on the nil actor.
      {forum, topic} = visible_topic()

      assert Topics.lock_topic(nil, forum.short_name, topic.slug, %{"lock_reason" => "Off topic"}) ==
               {:error, :unauthorized}

      assert Repo.reload!(topic).locked_at == nil
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Topics.lock_topic(
               confirmed_user_fixture(),
               "nonexistent",
               "whatever",
               %{"lock_reason" => "Off topic"}
             ) == {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.lock_topic(
               moderator_user_fixture(),
               forum.short_name,
               "nonexistent-topic",
               %{"lock_reason" => "Off topic"}
             ) == {:error, :not_found}
    end

    test "a moderator locks the topic, setting the timestamp, reason, and locker" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.lock_topic(moderator, forum.short_name, topic.slug, %{
                 "lock_reason" => "Off topic"
               })

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id

      locked = Repo.reload!(topic)
      assert locked.locked_at != nil
      assert locked.lock_reason == "Off topic"
      assert locked.locked_by_id == moderator.id
    end

    test "a successful lock writes a byte-exact moderation log" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, _} =
               Topics.lock_topic(moderator, forum.short_name, topic.slug, %{
                 "lock_reason" => "Off topic"
               })

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Topic.Lock:create"
      assert log.subject_path == "/forums/#{forum.short_name}/topics/#{topic.slug}"
      assert log.body == "Locked topic '#{topic.title}' (Off topic) in #{forum.name}"
    end

    test "a blank lock reason yields the 3-tuple error and writes no moderation log" do
      # lock_changeset requires lock_reason; lock_topic/4 surfaces the rejected
      # changeset as {:error, forum, topic} (both the loaded forum and the
      # pre-update topic) so the controller can still redirect.
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:error, error_forum, error_topic} =
               Topics.lock_topic(moderator, forum.short_name, topic.slug, %{"lock_reason" => ""})

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id

      assert Repo.reload!(topic).locked_at == nil
      assert moderation_log_count() == 0
    end
  end

  describe "unlock_topic/3" do
    test "a regular user cannot unlock a topic and it stays locked" do
      # Locking leaves the topic visible, so the loader admits a regular user,
      # who is then denied by the topic :hide permission.
      user = confirmed_user_fixture()
      {forum, topic} = locked_topic()

      assert Topics.unlock_topic(user, forum.short_name, topic.slug) == {:error, :unauthorized}
      assert Repo.reload!(topic).locked_at != nil
    end

    test "an anonymous actor cannot unlock a topic" do
      {forum, topic} = locked_topic()

      assert Topics.unlock_topic(nil, forum.short_name, topic.slug) == {:error, :unauthorized}
      assert Repo.reload!(topic).locked_at != nil
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Topics.unlock_topic(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.unlock_topic(moderator_user_fixture(), forum.short_name, "nonexistent-topic") ==
               {:error, :not_found}
    end

    test "a moderator unlocks the topic, clearing the timestamp, reason, and locker" do
      moderator = moderator_user_fixture()
      {forum, topic} = locked_topic()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.unlock_topic(moderator, forum.short_name, topic.slug)

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id

      unlocked = Repo.reload!(topic)
      assert unlocked.locked_at == nil
      assert unlocked.lock_reason == ""
      assert unlocked.locked_by_id == nil
    end

    test "a successful unlock writes a byte-exact moderation log" do
      moderator = moderator_user_fixture()
      {forum, topic} = locked_topic()

      assert {:ok, _} = Topics.unlock_topic(moderator, forum.short_name, topic.slug)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Topic.Lock:delete"
      assert log.subject_path == "/forums/#{forum.short_name}/topics/#{topic.slug}"
      assert log.body == "Unlocked topic '#{topic.title}' in #{forum.name}"
    end
  end

  describe "stick_topic/3" do
    test "a regular user cannot stick a visible topic and the topic stays unstuck" do
      # The visibility loader clears a regular user on a normal, visible topic;
      # the block on the topic :hide permission is what denies the stick.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      assert Topics.stick_topic(user, forum.short_name, topic.slug) == {:error, :unauthorized}

      refute Repo.reload!(topic).sticky
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot stick a visible topic" do
      # nil clears forum :show and topic visibility on normal content, but fails
      # the topic :hide permission, so this is a clean unauthorized rather than a
      # crash on the nil actor.
      {forum, topic} = visible_topic()

      assert Topics.stick_topic(nil, forum.short_name, topic.slug) == {:error, :unauthorized}

      refute Repo.reload!(topic).sticky
      assert moderation_log_count() == 0
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Topics.stick_topic(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.stick_topic(moderator_user_fixture(), forum.short_name, "nonexistent-topic") ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a moderator sticks the topic, setting the sticky flag" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.stick_topic(moderator, forum.short_name, topic.slug)

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id

      assert Repo.reload!(topic).sticky
    end

    test "a successful stick writes a byte-exact moderation log" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, _} = Topics.stick_topic(moderator, forum.short_name, topic.slug)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Topic.Stick:create"
      assert log.subject_path == "/forums/#{forum.short_name}/topics/#{topic.slug}"
      assert log.body == "Stickied topic '#{topic.title}' in #{forum.name}"
    end
  end

  describe "unstick_topic/3" do
    test "a regular user cannot unstick a topic and it stays sticky" do
      # Sticking leaves the topic visible, so the loader admits a regular user,
      # who is then denied by the topic :hide permission.
      user = confirmed_user_fixture()
      {forum, topic} = sticky_topic()

      assert Topics.unstick_topic(user, forum.short_name, topic.slug) == {:error, :unauthorized}

      assert Repo.reload!(topic).sticky
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot unstick a topic" do
      {forum, topic} = sticky_topic()

      assert Topics.unstick_topic(nil, forum.short_name, topic.slug) == {:error, :unauthorized}

      assert Repo.reload!(topic).sticky
      assert moderation_log_count() == 0
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Topics.unstick_topic(confirmed_user_fixture(), "nonexistent", "whatever") ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.unstick_topic(moderator_user_fixture(), forum.short_name, "nonexistent-topic") ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a moderator unsticks the topic, clearing the sticky flag" do
      moderator = moderator_user_fixture()
      {forum, topic} = sticky_topic()

      assert {:ok, {loaded_forum, loaded_topic}} =
               Topics.unstick_topic(moderator, forum.short_name, topic.slug)

      assert loaded_forum.id == forum.id
      assert loaded_topic.id == topic.id

      refute Repo.reload!(topic).sticky
    end

    test "unsticking a non-sticky topic still succeeds" do
      # unstick_changeset sets the column unconditionally, so a topic that was
      # never sticky is a successful no-op rather than an error.
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()
      refute Repo.reload!(topic).sticky

      assert {:ok, {_forum, _topic}} =
               Topics.unstick_topic(moderator, forum.short_name, topic.slug)

      refute Repo.reload!(topic).sticky
    end

    test "a successful unstick writes a byte-exact moderation log" do
      moderator = moderator_user_fixture()
      {forum, topic} = sticky_topic()

      assert {:ok, _} = Topics.unstick_topic(moderator, forum.short_name, topic.slug)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Topic.Stick:delete"
      assert log.subject_path == "/forums/#{forum.short_name}/topics/#{topic.slug}"
      assert log.body == "Unstickied topic '#{topic.title}' in #{forum.name}"
    end
  end

  describe "move_topic/4" do
    test "a regular user is unauthorized even with a malformed target, pinning authorize-before-parse" do
      # The forum/topic load and the :hide authorization run before the target
      # id is parsed, so an unprivileged actor sending garbage still answers
      # unauthorized rather than the bespoke parse failure. The topic stays put
      # and no log row is written.
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      assert Topics.move_topic(user, forum.short_name, topic.slug, %{
               "target_forum_id" => "garbage"
             }) == {:error, :unauthorized}

      assert Repo.reload!(topic).forum_id == forum.id
      assert moderation_log_count() == 0
    end

    test "an anonymous actor is unauthorized" do
      # nil clears forum :show and topic visibility on normal content, but fails
      # the topic :hide permission, so this is a clean unauthorized.
      {forum, topic} = visible_topic()
      target = forum_fixture()

      assert Topics.move_topic(nil, forum.short_name, topic.slug, %{
               "target_forum_id" => to_string(target.id)
             }) == {:error, :unauthorized}

      assert Repo.reload!(topic).forum_id == forum.id
      assert moderation_log_count() == 0
    end

    test "an unknown source forum is unauthorized for a regular user" do
      target = forum_fixture()

      assert Topics.move_topic(confirmed_user_fixture(), "nonexistent", "whatever", %{
               "target_forum_id" => to_string(target.id)
             }) == {:error, :unauthorized}
    end

    test "an existing source forum with an unknown topic is not found" do
      forum = forum_fixture()
      target = forum_fixture()

      assert Topics.move_topic(moderator_user_fixture(), forum.short_name, "nonexistent-topic", %{
               "target_forum_id" => to_string(target.id)
             }) == {:error, :not_found}
    end

    test "a moderator moves the topic, changing forum_id and updating both forum counts" do
      moderator = moderator_user_fixture()
      forum = forum_fixture()
      topic = topic_fixture(forum)
      target = forum_fixture()

      # create_topic left the source forum at topic_count 1 and the empty target
      # at topic_count 0; the move engine's Multi shifts one topic across.
      assert Repo.reload!(forum).topic_count == 1
      assert Repo.reload!(target).topic_count == 0

      assert {:ok, {new_forum, moved_topic}} =
               Topics.move_topic(moderator, forum.short_name, topic.slug, %{
                 "target_forum_id" => to_string(target.id)
               })

      assert new_forum.id == target.id
      assert moved_topic.forum_id == target.id
      assert Repo.reload!(topic).forum_id == target.id

      assert Repo.reload!(forum).topic_count == 0
      assert Repo.reload!(target).topic_count == 1
    end

    test "a successful move writes a byte-exact moderation log against the NEW forum" do
      moderator = moderator_user_fixture()
      forum = forum_fixture()
      topic = topic_fixture(forum)
      target = forum_fixture()

      assert {:ok, _} =
               Topics.move_topic(moderator, forum.short_name, topic.slug, %{
                 "target_forum_id" => to_string(target.id)
               })

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Topic.Move:create"
      assert log.subject_path == "/forums/#{target.short_name}/topics/#{topic.slug}"
      assert log.body == "Topic '#{topic.title}' moved to #{target.name}"
    end

    test "a moderator with nil topic_params gets the 3-tuple error, no move, no log" do
      # A missing "topic" param arrives as nil; parse_target_forum_id tolerates
      # it and funnels to the bespoke failure carrying the SOURCE forum and
      # topic, so the controller can redirect back.
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:error, error_forum, error_topic} =
               Topics.move_topic(moderator, forum.short_name, topic.slug, nil)

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id

      assert Repo.reload!(topic).forum_id == forum.id
      assert moderation_log_count() == 0
    end

    test "a moderator with a non-integer target id gets the 3-tuple error, no move, no log" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:error, error_forum, error_topic} =
               Topics.move_topic(moderator, forum.short_name, topic.slug, %{
                 "target_forum_id" => "not-a-number"
               })

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id

      assert Repo.reload!(topic).forum_id == forum.id
      assert moderation_log_count() == 0
    end

    test "a moderator with a nonexistent target forum id gets the 3-tuple error, no move, no log" do
      # A well-formed id whose forum does not exist is caught by the
      # move_changeset FK constraint and normalized to a changeset failure, which
      # surfaces as the same {:error, source_forum, topic} the parse failures do.
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:error, error_forum, error_topic} =
               Topics.move_topic(moderator, forum.short_name, topic.slug, %{
                 "target_forum_id" => "999999999"
               })

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id

      assert Repo.reload!(topic).forum_id == forum.id
      assert moderation_log_count() == 0
    end
  end

  describe "load_topic_page/5" do
    test "an anonymous visitor reaches a visible topic with raw posts and both changesets" do
      {forum, topic} = visible_topic()

      assert {:ok, %TopicPage{} = page} =
               Topics.load_topic_page(nil, forum.short_name, topic.slug, nil, @first_page)

      assert page.forum.id == forum.id
      assert page.topic.id == topic.id

      # The page entries are raw Post structs, not rendered markup.
      assert [%Post{}] = page.posts.entries
      assert page.posts.page_size == 25

      assert page.watching == false
      # A topic with no poll reports its poll as inactive.
      assert page.poll_active == false

      assert %Ecto.Changeset{} = page.post_changeset
      assert %Ecto.Changeset{} = page.topic_changeset
    end

    test "a hidden topic is unauthorized for a regular user" do
      user = confirmed_user_fixture()
      {forum, topic} = hidden_topic()

      assert Topics.load_topic_page(user, forum.short_name, topic.slug, nil, @first_page) ==
               {:error, :unauthorized}
    end

    test "an unknown forum is unauthorized for a regular user" do
      assert Topics.load_topic_page(
               confirmed_user_fixture(),
               "nonexistent",
               "whatever",
               nil,
               @first_page
             ) == {:error, :unauthorized}
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.load_topic_page(
               confirmed_user_fixture(),
               forum.short_name,
               "nonexistent-topic",
               nil,
               @first_page
             ) == {:error, :not_found}
    end

    test "a post_id naming a post on the second page derives that page over the pagination" do
      # The first post sits at topic_position 0; 25 replies fill positions 1..25,
      # so the last reply falls on page 2 (div(25, 25) + 1) even though the
      # pagination map asks for page 1.
      {forum, topic} = visible_topic()

      replies = for _ <- 1..25, do: post_fixture(topic)
      last = List.last(replies)
      assert last.topic_position == 25

      assert {:ok, page} =
               Topics.load_topic_page(nil, forum.short_name, topic.slug, to_string(last.id), %{
                 page_number: 1
               })

      assert page.posts.page_number == 2
      assert Enum.map(page.posts.entries, & &1.id) == [last.id]
    end

    test "a subscribed user has watching set true" do
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()
      {:ok, _} = Topics.create_subscription(topic, user)

      assert {:ok, page} =
               Topics.load_topic_page(user, forum.short_name, topic.slug, nil, @first_page)

      assert page.watching
    end

    test "loading the page clears the user's topic notification" do
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      {:ok, _} = Topics.create_subscription(topic, user)
      author = confirmed_user_fixture()
      post = hd(topic.posts)
      {:ok, 1} = Notifications.create_forum_post_notification(author, topic, post)
      assert post_notification?(topic, user)

      assert {:ok, _page} =
               Topics.load_topic_page(user, forum.short_name, topic.slug, nil, @first_page)

      refute post_notification?(topic, user)
    end
  end

  describe "load_new_topic/2" do
    test "a banned actor is rejected before any loading" do
      # verify_not_banned runs first, so a banned actor is {:error, :ban} even
      # against a forum slug that does not exist.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Topics.load_new_topic(actor, "nonexistent") == {:error, :ban}
    end

    test "a regular actor gets the forum and a changeset seeded with a poll and one post" do
      forum = forum_fixture()

      assert {:ok, {loaded_forum, changeset}} =
               Topics.load_new_topic(actor(confirmed_user_fixture()), forum.short_name)

      assert loaded_forum.id == forum.id
      assert %Ecto.Changeset{} = changeset
      assert length(changeset.data.poll.options) == 2
      assert length(changeset.data.posts) == 1
    end

    test "an unknown forum is unauthorized for a regular actor" do
      assert Topics.load_new_topic(actor(confirmed_user_fixture()), "nonexistent") ==
               {:error, :unauthorized}
    end
  end

  describe "create_topic/3" do
    @valid_topic_params %{
      "title" => "A brand new topic",
      "anonymous" => "false",
      "posts" => %{"0" => %{"body" => "First post body"}}
    }

    test "a banned actor is rejected before any loading" do
      # verify_write_access runs first, so a banned actor is {:error, :ban} even
      # against a forum slug that does not exist.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Topics.create_topic(actor, "nonexistent", @valid_topic_params) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Topics.create_topic(actor, "nonexistent", @valid_topic_params) ==
               {:error, :unauthorized}
    end

    test "a valid signed-in actor creates the topic with its first post" do
      forum = forum_fixture()
      user = confirmed_user_fixture()

      assert {:ok, %{topic: topic, forum: loaded_forum, post: post}} =
               Topics.create_topic(actor(user), forum.short_name, @valid_topic_params)

      assert loaded_forum.id == forum.id
      assert topic.title == "A brand new topic"
      assert topic.user_id == user.id
      assert post.topic_id == topic.id

      assert Repo.get(Topic, topic.id)
      assert Repo.reload!(post).body == "First post body"
    end

    test "blank params yield the changeset error carrying the forum" do
      forum = forum_fixture()
      user = confirmed_user_fixture()

      params = %{
        "title" => "",
        "anonymous" => "false",
        "posts" => %{"0" => %{"body" => ""}}
      }

      assert {:error, error_forum, %Ecto.Changeset{}} =
               Topics.create_topic(actor(user), forum.short_name, params)

      assert error_forum.id == forum.id
    end

    test "an unknown forum is unauthorized for a valid actor" do
      assert Topics.create_topic(
               actor(confirmed_user_fixture()),
               "nonexistent",
               @valid_topic_params
             ) == {:error, :unauthorized}
    end
  end

  describe "update_topic_title/4" do
    test "a regular user cannot edit a topic title and it stays unchanged" do
      user = confirmed_user_fixture()
      {forum, topic} = visible_topic()

      assert Topics.update_topic_title(user, forum.short_name, topic.slug, %{
               "title" => "New Title"
             }) == {:error, :unauthorized}

      assert Repo.reload!(topic).title == topic.title
    end

    test "a moderator updates the title" do
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()

      assert {:ok, {loaded_forum, updated_topic}} =
               Topics.update_topic_title(moderator, forum.short_name, topic.slug, %{
                 "title" => "Renamed topic"
               })

      assert loaded_forum.id == forum.id
      assert updated_topic.title == "Renamed topic"
      assert Repo.reload!(topic).title == "Renamed topic"
    end

    test "a blank title yields the 3-tuple error and leaves the title unchanged" do
      # title_changeset requires the title, so a blank one surfaces as
      # {:error, forum, topic} (both the loaded forum and the pre-update topic).
      moderator = moderator_user_fixture()
      {forum, topic} = visible_topic()
      original_title = topic.title

      assert {:error, error_forum, error_topic} =
               Topics.update_topic_title(moderator, forum.short_name, topic.slug, %{"title" => ""})

      assert error_forum.id == forum.id
      assert error_topic.id == topic.id
      assert Repo.reload!(topic).title == original_title
    end

    test "an existing forum with an unknown topic is not found" do
      forum = forum_fixture()

      assert Topics.update_topic_title(
               moderator_user_fixture(),
               forum.short_name,
               "nonexistent-topic",
               %{"title" => "New Title"}
             ) == {:error, :not_found}
    end
  end
end
