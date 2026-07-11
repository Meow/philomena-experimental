defmodule Philomena.PostsTest do
  @moduledoc """
  Context-level tests for the actor-first `Philomena.Posts` API.

  These pin the authorization matrix (anonymous/user/moderator), the two
  global error shapes routed through the id guard, and the moderation log
  entry - type string, body, and subject path byte-for-byte - that
  `approve_post/2`, `hide_post/3`, and `unhide_post/2` write on success. The
  corresponding controller characterization tests pin the HTTP behavior on top
  of these results.
  """

  use Philomena.DataCase, async: true

  import Philomena.ForumsFixtures
  import Philomena.PostsFixtures
  import Philomena.TopicsFixtures
  import Philomena.UsersFixtures

  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Posts
  alias Philomena.Posts.Post
  alias Philomena.Forums.Forum
  alias Philomena.Repo
  alias Philomena.Users.User

  setup do
    forum = forum_fixture()
    topic = topic_fixture(forum)

    %{forum: forum, topic: topic}
  end

  # A post authored by a fresh (untrusted) user containing an external link is
  # not auto-approved on creation (see Philomena.Schema.Approval); returns the
  # post together with its author so the posts_count bump can be checked.
  defp unapproved_post(topic) do
    author = confirmed_user_fixture()

    post =
      post_fixture(topic, author, %{
        "body" => "check this out https://spam.example/"
      })

    refute post.approved
    {post, author}
  end

  defp no_moderation_logs! do
    assert Repo.aggregate(ModerationLog, :count) == 0
  end

  describe "approve_post/2" do
    test "denies an anonymous actor", %{topic: topic} do
      {post, _author} = unapproved_post(topic)

      assert Posts.approve_post(nil, "#{post.id}") == {:error, :unauthorized}
      refute Repo.reload!(post).approved
      no_moderation_logs!()
    end

    test "denies a regular user", %{topic: topic} do
      {post, _author} = unapproved_post(topic)

      assert Posts.approve_post(confirmed_user_fixture(), "#{post.id}") == {:error, :unauthorized}
      refute Repo.reload!(post).approved
      no_moderation_logs!()
    end

    test "a moderator approves the post, which is returned with topic and forum preloaded",
         %{forum: forum, topic: topic} do
      {post, _author} = unapproved_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, %Post{} = approved} = Posts.approve_post(moderator, "#{post.id}")

      assert approved.id == post.id
      assert approved.approved
      assert %{topic: %{forum: %Forum{}}} = approved
      assert approved.topic.id == topic.id
      assert approved.topic.forum.id == forum.id

      assert Repo.reload!(post).approved
    end

    test "the moderation log names the post and topic byte-for-byte",
         %{forum: forum, topic: topic} do
      {post, _author} = unapproved_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Posts.approve_post(moderator, "#{post.id}")

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Topic.Post.Approve:create"
      assert log.body == "Approved forum post ##{post.id} in topic '#{topic.title}'"

      assert log.subject_path ==
               "/forums/#{forum.short_name}/topics/#{topic.slug}?post_id=#{post.id}#post_#{post.id}"
    end

    test "approving increments the author's forum posts_count by one", %{topic: topic} do
      {post, author} = unapproved_post(topic)
      before = Repo.get!(User, author.id).posts_count

      assert {:ok, _} = Posts.approve_post(moderator_user_fixture(), "#{post.id}")

      assert Repo.get!(User, author.id).posts_count == before + 1
    end

    # A well-formed id naming no row loads nil, which no :approve rule permits;
    # the context returns unauthorized rather than not-found, preserving the
    # behavior of the load-then-authorize plug it replaces.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Posts.approve_post(moderator_user_fixture(), "999999999") == {:error, :unauthorized}
      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Posts.approve_post(moderator_user_fixture(), "abc") == {:error, :not_found}
      no_moderation_logs!()
    end
  end

  # A visible reply authored by a fresh user, ready to be hidden.
  defp visible_post(topic) do
    post_fixture(topic, confirmed_user_fixture(), %{"body" => "Rule-breaking post"})
  end

  # An already-hidden reply, set up through the auth-free/log-free engine so no
  # moderation log exists before the restore under test runs.
  defp already_hidden_post(topic) do
    {:ok, hidden} =
      Posts.hide_loaded_post(
        visible_post(topic),
        %{"deletion_reason" => "Spam"},
        moderator_user_fixture()
      )

    hidden
  end

  describe "hide_post/3" do
    test "denies an anonymous actor", %{topic: topic} do
      post = visible_post(topic)

      assert Posts.hide_post(nil, "#{post.id}", %{"deletion_reason" => "Spam"}) ==
               {:error, :unauthorized}

      refute Repo.reload!(post).hidden_from_users
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the post unchanged", %{topic: topic} do
      post = visible_post(topic)

      assert Posts.hide_post(confirmed_user_fixture(), "#{post.id}", %{
               "deletion_reason" => "Spam"
             }) ==
               {:error, :unauthorized}

      reloaded = Repo.reload!(post)
      refute reloaded.hidden_from_users
      assert reloaded.deletion_reason == ""
      no_moderation_logs!()
    end

    test "a moderator hides the post, which is returned with topic and forum preloaded",
         %{forum: forum, topic: topic} do
      post = visible_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, %Post{} = hidden} =
               Posts.hide_post(moderator, "#{post.id}", %{"deletion_reason" => "Spam"})

      assert hidden.id == post.id
      assert hidden.hidden_from_users
      assert hidden.deletion_reason == "Spam"
      assert %{topic: %{forum: %Forum{}}} = hidden
      assert hidden.topic.id == topic.id
      assert hidden.topic.forum.id == forum.id

      reloaded = Repo.reload!(post)
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Spam"
    end

    test "the moderation log names the post, topic, and reason byte-for-byte",
         %{forum: forum, topic: topic} do
      post = visible_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Posts.hide_post(moderator, "#{post.id}", %{"deletion_reason" => "Spam"})

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Topic.Post.Hide:create"
      assert log.body == "Deleted forum post ##{post.id} in topic '#{topic.title}' (Spam)"

      assert log.subject_path ==
               "/forums/#{forum.short_name}/topics/#{topic.slug}?post_id=#{post.id}#post_#{post.id}"
    end

    test "a blank deletion reason is a rejected changeset carrying the loaded post",
         %{topic: topic} do
      post = visible_post(topic)

      assert {:error, %Post{} = returned} =
               Posts.hide_post(moderator_user_fixture(), "#{post.id}", %{"deletion_reason" => ""})

      assert returned.id == post.id
      refute Repo.reload!(post).hidden_from_users
      no_moderation_logs!()
    end

    # A well-formed id naming no row loads nil, which no :hide rule permits; the
    # context returns unauthorized rather than not-found, preserving the behavior
    # of the load-then-authorize plug it replaces.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Posts.hide_post(moderator_user_fixture(), "999999999", %{"deletion_reason" => "Spam"}) ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Posts.hide_post(moderator_user_fixture(), "abc", %{"deletion_reason" => "Spam"}) ==
               {:error, :not_found}

      no_moderation_logs!()
    end
  end

  describe "unhide_post/2" do
    test "denies an anonymous actor", %{topic: topic} do
      post = already_hidden_post(topic)

      assert Posts.unhide_post(nil, "#{post.id}") == {:error, :unauthorized}
      assert Repo.reload!(post).hidden_from_users
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the post hidden", %{topic: topic} do
      post = already_hidden_post(topic)

      assert Posts.unhide_post(confirmed_user_fixture(), "#{post.id}") == {:error, :unauthorized}

      reloaded = Repo.reload!(post)
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Spam"
      no_moderation_logs!()
    end

    test "a moderator restores the post, which is returned with topic and forum preloaded",
         %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, %Post{} = restored} = Posts.unhide_post(moderator, "#{post.id}")

      assert restored.id == post.id
      refute restored.hidden_from_users
      assert restored.deletion_reason == ""
      assert %{topic: %{forum: %Forum{}}} = restored
      assert restored.topic.id == topic.id
      assert restored.topic.forum.id == forum.id

      reloaded = Repo.reload!(post)
      refute reloaded.hidden_from_users
      assert reloaded.deletion_reason == ""
    end

    test "the moderation log names the post and topic byte-for-byte",
         %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Posts.unhide_post(moderator, "#{post.id}")

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Topic.Post.Hide:delete"
      assert log.body == "Restored forum post ##{post.id} in topic '#{topic.title}'"

      assert log.subject_path ==
               "/forums/#{forum.short_name}/topics/#{topic.slug}?post_id=#{post.id}#post_#{post.id}"
    end

    # As with hide_post/3, a well-formed id naming no row loads nil and is
    # unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Posts.unhide_post(moderator_user_fixture(), "999999999") == {:error, :unauthorized}
      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Posts.unhide_post(moderator_user_fixture(), "abc") == {:error, :not_found}
      no_moderation_logs!()
    end
  end
end
