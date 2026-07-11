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

  import Philomena.AttributionFixtures
  import Philomena.ForumsFixtures
  import Philomena.PostsFixtures
  import Philomena.TopicsFixtures
  import Philomena.UsersFixtures

  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Posts
  alias Philomena.Posts.Post
  alias Philomena.Forums.Forum
  alias Philomena.Reports.Report
  alias Philomena.Repo
  alias Philomena.Users.User
  alias Philomena.Versions.Version

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to the write-access and
  # not-banned checks the report loaders run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

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

  describe "destroy_post/2" do
    test "denies an anonymous actor, leaving the body intact", %{topic: topic} do
      post = visible_post(topic)

      assert Posts.destroy_post(nil, "#{post.id}") == {:error, :unauthorized}

      reloaded = Repo.reload!(post)
      assert reloaded.body == "Rule-breaking post"
      refute reloaded.destroyed_content
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the body intact", %{topic: topic} do
      post = visible_post(topic)

      assert Posts.destroy_post(confirmed_user_fixture(), "#{post.id}") == {:error, :unauthorized}

      reloaded = Repo.reload!(post)
      assert reloaded.body == "Rule-breaking post"
      refute reloaded.destroyed_content
      no_moderation_logs!()
    end

    test "a moderator destroys the post, which is returned with topic and forum preloaded",
         %{forum: forum, topic: topic} do
      post = visible_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, %Post{} = destroyed} = Posts.destroy_post(moderator, "#{post.id}")

      assert destroyed.id == post.id
      assert %{topic: %{forum: %Forum{}}} = destroyed
      assert destroyed.topic.id == topic.id
      assert destroyed.topic.forum.id == forum.id

      # The destroy engine blanks the body and marks the content destroyed; it
      # does not touch the post's hidden/deletion_reason fields, so a visible
      # post stays visible while its text is wiped.
      reloaded = Repo.reload!(post)
      assert reloaded.body == ""
      assert reloaded.destroyed_content
      refute reloaded.hidden_from_users
      assert reloaded.deletion_reason == ""
    end

    # The engine authorizes :hide and never inspects hidden_from_users, so an
    # already-hidden post is destroyable too; it keeps its hidden flag and reason
    # while the text is wiped.
    test "destroys an already-hidden post, keeping its hidden flag and reason", %{topic: topic} do
      post = already_hidden_post(topic)

      # Set up through the log-free engine, so no log exists before the destroy.
      no_moderation_logs!()

      assert {:ok, %Post{}} = Posts.destroy_post(moderator_user_fixture(), "#{post.id}")

      reloaded = Repo.reload!(post)
      assert reloaded.body == ""
      assert reloaded.destroyed_content
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Spam"
    end

    test "the moderation log names the post and topic byte-for-byte",
         %{forum: forum, topic: topic} do
      post = visible_post(topic)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Posts.destroy_post(moderator, "#{post.id}")

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Topic.Post.Delete:create"
      assert log.body == "Destroyed forum post ##{post.id} in topic '#{topic.title}'"

      assert log.subject_path ==
               "/forums/#{forum.short_name}/topics/#{topic.slug}?post_id=#{post.id}#post_#{post.id}"
    end

    # As with the other id-guarded actions, a well-formed id naming no row loads
    # nil and is unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Posts.destroy_post(moderator_user_fixture(), "999999999") == {:error, :unauthorized}
      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Posts.destroy_post(moderator_user_fixture(), "abc") == {:error, :not_found}
      no_moderation_logs!()
    end
  end

  describe "post_history/4" do
    # Unlike the moderation actions above, post_history is a public read routed
    # by forum short name and topic slug (not a bare post id), so it takes the
    # loaded topic's addressing rather than a raw "#{post.id}" string.

    test "an anonymous actor reads the history of a visible post",
         %{forum: forum, topic: topic} do
      [post] = topic.posts

      assert {:ok, {loaded_topic, %Post{} = loaded_post, versions}} =
               Posts.post_history(nil, forum.short_name, topic.slug, "#{post.id}")

      assert loaded_topic.id == topic.id
      assert loaded_post.id == post.id

      # The post comes back with the associations the history page renders.
      assert %{topic: %{forum: %Forum{}}} = loaded_post
      assert loaded_post.topic.id == topic.id
      assert loaded_post.topic.forum.id == forum.id

      # A never-edited post has recorded no versions.
      assert versions == []
    end

    test "an unknown forum is unauthorized", %{topic: topic} do
      [post] = topic.posts

      assert Posts.post_history(nil, "nonexistent", topic.slug, "#{post.id}") ==
               {:error, :unauthorized}
    end

    test "an unknown topic in a real forum is not found", %{forum: forum} do
      assert Posts.post_history(nil, forum.short_name, "nonexistent", "1") ==
               {:error, :not_found}
    end

    test "an unknown post id in a real topic is not found", %{forum: forum, topic: topic} do
      assert Posts.post_history(nil, forum.short_name, topic.slug, "999999999") ==
               {:error, :not_found}
    end

    test "an anonymous actor cannot read the history of a hidden post",
         %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)

      assert Posts.post_history(nil, forum.short_name, topic.slug, "#{post.id}") ==
               {:error, :unauthorized}
    end

    test "a regular user cannot read the history of a hidden post",
         %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)

      assert Posts.post_history(
               confirmed_user_fixture(),
               forum.short_name,
               topic.slug,
               "#{post.id}"
             ) ==
               {:error, :unauthorized}
    end

    test "a moderator reads the history of a hidden post", %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)

      assert {:ok, {_topic, %Post{} = loaded_post, versions}} =
               Posts.post_history(
                 moderator_user_fixture(),
                 forum.short_name,
                 topic.slug,
                 "#{post.id}"
               )

      assert loaded_post.id == post.id
      assert loaded_post.hidden_from_users
      assert is_list(versions)
    end

    test "an edited post reports the recorded version, its author, and the pre-edit body",
         %{forum: forum, topic: topic} do
      author = confirmed_user_fixture()
      post = post_fixture(topic, author, %{"body" => "Original post body"})

      {:ok, _} =
        Posts.update_post(post, author, %{
          "body" => "Original post body plus an edit",
          "edit_reason" => "typo fix"
        })

      assert {:ok, {_topic, _post, [%Version{} = version]}} =
               Posts.post_history(nil, forum.short_name, topic.slug, "#{post.id}")

      # create_version records the body as it stood before the edit, so the
      # single version carries the original text and names its editor.
      assert version.body == "Original post body"
      assert version.user.id == author.id
    end

    test "the history is capped at the most recent 25 versions",
         %{forum: forum, topic: topic} do
      author = confirmed_user_fixture()
      post = post_fixture(topic, author, %{"body" => "edit 0"})

      # Each update records one version, so 26 edits record 26 versions; the
      # query limits the result to 25. Ordering among versions is not pinned:
      # created_at has second precision, so edits within the same second tie and
      # the surviving order is left to the database.
      Enum.reduce(1..26, post, fn n, current ->
        {:ok, %{post: updated}} =
          Posts.update_post(current, author, %{"body" => "edit #{n}"})

        updated
      end)

      assert {:ok, {_topic, _post, versions}} =
               Posts.post_history(nil, forum.short_name, topic.slug, "#{post.id}")

      assert length(versions) == 25
    end
  end

  describe "load_post_for_report/4" do
    # This backs the report form (a GET-guarded action), so it runs
    # verify_not_banned first and then the same forum/topic/post load-and-authorize
    # chain as post_history/4. Unlike the creation path, it enforces no fingerprint
    # requirement.

    test "a banned actor is rejected before any loading, even with an unknown forum" do
      # verify_not_banned runs before the loader, so a banned actor is {:error, :ban}
      # even against a forum slug that does not exist (a missing forum would
      # otherwise surface as :unauthorized). Getting :ban pins that the ban check
      # precedes the load.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Posts.load_post_for_report(actor, "nonexistent", "whatever", "1") ==
               {:error, :ban}
    end

    test "an anonymous actor with no fingerprint loads the report form for a visible post",
         %{forum: forum, topic: topic} do
      # The GET path checks only the ban, never the fingerprint, so a non-banned
      # anonymous actor carrying no fingerprint still succeeds here (the creation
      # path below rejects the same actor as unauthorized).
      [post] = topic.posts
      anonymous = actor(nil, fingerprint: nil)

      assert {:ok, {loaded_topic, %Post{} = loaded_post, %Ecto.Changeset{} = changeset}} =
               Posts.load_post_for_report(anonymous, forum.short_name, topic.slug, "#{post.id}")

      assert loaded_topic.id == topic.id
      assert loaded_post.id == post.id

      # The topic carries its forum preloaded for building the form action.
      assert %Forum{} = loaded_topic.forum
      assert loaded_topic.forum.id == forum.id

      # The changeset is over a Report addressed at this post.
      assert %Report{} = changeset.data
      assert changeset.data.reportable_type == "Post"
      assert changeset.data.reportable_id == post.id
    end

    test "an unknown forum is unauthorized", %{topic: topic} do
      [post] = topic.posts

      assert Posts.load_post_for_report(actor(nil), "nonexistent", topic.slug, "#{post.id}") ==
               {:error, :unauthorized}
    end

    test "an unknown topic in a real forum is not found", %{forum: forum} do
      assert Posts.load_post_for_report(actor(nil), forum.short_name, "nonexistent", "1") ==
               {:error, :not_found}
    end

    test "an unknown post id in a real topic is not found", %{forum: forum, topic: topic} do
      assert Posts.load_post_for_report(actor(nil), forum.short_name, topic.slug, "999999999") ==
               {:error, :not_found}
    end

    test "a regular user cannot load a hidden post's report form",
         %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)

      assert Posts.load_post_for_report(
               actor(confirmed_user_fixture()),
               forum.short_name,
               topic.slug,
               "#{post.id}"
             ) ==
               {:error, :unauthorized}
    end

    test "a moderator loads a hidden post's report form", %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)

      assert {:ok, {_topic, %Post{} = loaded_post, %Ecto.Changeset{}}} =
               Posts.load_post_for_report(
                 actor(moderator_user_fixture()),
                 forum.short_name,
                 topic.slug,
                 "#{post.id}"
               )

      assert loaded_post.id == post.id
      assert loaded_post.hidden_from_users
    end
  end

  describe "load_post_for_report_creation/4" do
    # This backs the report submission (a write), so it runs verify_write_access
    # first (ban -> :ban, missing fingerprint -> :unauthorized) and then the same
    # forum/topic/post load-and-authorize chain as post_history/4.

    test "a banned actor is rejected before any loading, even with an unknown forum" do
      # verify_write_access runs first, so a banned actor is {:error, :ban} even
      # against a forum slug that does not exist.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Posts.load_post_for_report_creation(actor, "nonexistent", "whatever", "1") ==
               {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading, signed in or not" do
      # The fingerprint requirement applies regardless of whether a user is signed
      # in, and precedes loading, so a missing forum still answers unauthorized
      # from the write-access gate rather than the loader.
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert Posts.load_post_for_report_creation(signed_in, "nonexistent", "whatever", "1") ==
               {:error, :unauthorized}

      assert Posts.load_post_for_report_creation(anonymous, "nonexistent", "whatever", "1") ==
               {:error, :unauthorized}
    end

    test "a valid signed-in actor loads a visible post", %{forum: forum, topic: topic} do
      [post] = topic.posts

      assert {:ok, {loaded_topic, %Post{} = loaded_post}} =
               Posts.load_post_for_report_creation(
                 actor(confirmed_user_fixture()),
                 forum.short_name,
                 topic.slug,
                 "#{post.id}"
               )

      assert loaded_topic.id == topic.id
      assert loaded_post.id == post.id

      # The topic carries its forum preloaded for building the redirect action.
      assert %Forum{} = loaded_topic.forum
      assert loaded_topic.forum.id == forum.id
    end

    test "a valid anonymous fingerprinted actor loads a visible post",
         %{forum: forum, topic: topic} do
      # actor(nil) carries the shared fingerprint, so it clears verify_write_access
      # and reaches the public forum/topic/post load.
      [post] = topic.posts

      assert {:ok, {_topic, %Post{} = loaded_post}} =
               Posts.load_post_for_report_creation(
                 actor(nil),
                 forum.short_name,
                 topic.slug,
                 "#{post.id}"
               )

      assert loaded_post.id == post.id
    end

    test "a regular user cannot load a hidden post", %{forum: forum, topic: topic} do
      post = already_hidden_post(topic)

      assert Posts.load_post_for_report_creation(
               actor(confirmed_user_fixture()),
               forum.short_name,
               topic.slug,
               "#{post.id}"
             ) ==
               {:error, :unauthorized}
    end
  end
end
