defmodule Philomena.PostsTest do
  @moduledoc """
  Context-level tests for the actor-first `Philomena.Posts` API.

  These pin the authorization matrix (anonymous/user/moderator), the two
  global error shapes routed through the id guard, and the moderation log
  entry - type string, body, and subject path byte-for-byte - that
  `approve_post/2` writes on success. The corresponding controller
  characterization tests pin the HTTP behavior on top of these results.
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
end
