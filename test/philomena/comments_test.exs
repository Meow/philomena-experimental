defmodule Philomena.CommentsTest do
  @moduledoc """
  Context-level tests for `Philomena.Comments`.

  `search_comments/4` runs a comment search against OpenSearch and applies the
  viewer's visibility rules. `approve_comment/2` is the actor-first moderation
  wrapper: it pins the authorization matrix, the two global error shapes routed
  through the id guard, the approval effects (report closure, author comment
  count, reindex), and the moderation log entry - type, body, and subject path
  asserted exactly.
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.AttributionFixtures
  import Philomena.CommentsFixtures
  import Philomena.ImagesFixtures
  import Philomena.ReportsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Comments
  alias Philomena.Filters.Filter
  alias Philomena.Repo
  alias Philomena.Comments.Comment
  alias Philomena.Comments.CommentVersion
  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Reports.Report
  alias Philomena.Users.User
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to the write-access and
  # not-banned checks the actor-first writes run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

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
                 actor(),
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
               Comments.search_comments(actor(), @empty_filter, "grapefruit", @pagination)

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
               Comments.search_comments(actor(), @empty_filter, "grapefruit", @pagination)

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
               Comments.search_comments(
                 actor(moderator),
                 @empty_filter,
                 "grapefruit",
                 @pagination
               )

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
               Comments.search_comments(actor(), hidden_filter, "grapefruit", @pagination)

      assert results.entries == []

      # The same comment is visible when the tag is not hidden.
      assert {:ok, results} =
               Comments.search_comments(actor(), @empty_filter, "grapefruit", @pagination)

      assert [_entry] = results.entries
    end
  end

  # A comment authored by a fresh (untrusted) user containing an external link
  # is not auto-approved on creation (see Philomena.Schema.Approval); returns the
  # comment together with its author so the comments_count bump can be checked.
  defp unapproved_comment(image) do
    author = confirmed_user_fixture()

    comment =
      comment_fixture(image, author, %{"body" => "check this out https://spam.example/"})

    refute comment.approved
    {comment, author}
  end

  defp no_moderation_logs! do
    assert Repo.aggregate(ModerationLog, :count) == 0
  end

  describe "approve_comment/2" do
    setup do
      %{image: image_fixture()}
    end

    test "denies an anonymous actor", %{image: image} do
      {comment, _author} = unapproved_comment(image)

      assert Comments.approve_comment(actor(), "#{comment.id}") == {:error, :unauthorized}
      refute Repo.reload!(comment).approved
      no_moderation_logs!()
    end

    test "denies a regular user", %{image: image} do
      {comment, _author} = unapproved_comment(image)

      assert Comments.approve_comment(actor(confirmed_user_fixture()), "#{comment.id}") ==
               {:error, :unauthorized}

      refute Repo.reload!(comment).approved
      no_moderation_logs!()
    end

    test "a moderator approves the comment, which is returned approved", %{image: image} do
      {comment, _author} = unapproved_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, %Comment{} = approved} =
               Comments.approve_comment(actor(moderator), "#{comment.id}")

      assert approved.id == comment.id
      assert approved.approved

      assert Repo.reload!(comment).approved
    end

    test "the moderation log names the image and comment exactly", %{image: image} do
      {comment, _author} = unapproved_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Comments.approve_comment(actor(moderator), "#{comment.id}")

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Image.Comment.Approve:create"
      assert log.body == "Approved comment on image #{image.id}"
      assert log.subject_path == "/images/#{image.id}#comment_#{comment.id}"
    end

    test "approving increments the author's comments_count by one", %{image: image} do
      {comment, author} = unapproved_comment(image)
      before = Repo.get!(User, author.id).comments_count

      assert {:ok, _} = Comments.approve_comment(actor(moderator_user_fixture()), "#{comment.id}")

      assert Repo.get!(User, author.id).comments_count == before + 1
    end

    test "approving closes the comment's open reports", %{image: image} do
      {comment, _author} = unapproved_comment(image)
      report = report_fixture(confirmed_user_fixture(), comment_id: comment.id)

      assert report.open
      assert report.state == "open"

      assert {:ok, _} = Comments.approve_comment(actor(moderator_user_fixture()), "#{comment.id}")

      closed = Repo.get!(Report, report.id)
      refute closed.open
      assert closed.state == "closed"
    end

    # Approving an already-approved comment succeeds and re-logs; the comment
    # count bump runs unconditionally, so it also increments the author's count.
    test "approving an already-approved comment succeeds and logs again", %{image: image} do
      author = confirmed_user_fixture()
      comment = comment_fixture(image, author, %{"body" => "A perfectly ordinary comment"})
      assert comment.approved

      before = Repo.get!(User, author.id).comments_count

      assert {:ok, %Comment{} = approved} =
               Comments.approve_comment(actor(moderator_user_fixture()), "#{comment.id}")

      assert approved.approved
      assert Repo.get!(User, author.id).comments_count == before + 1

      log = Repo.one!(ModerationLog)
      assert log.type == "Image.Comment.Approve:create"
      assert log.body == "Approved comment on image #{image.id}"
    end

    # A well-formed id naming no row loads nil, which no :approve rule permits;
    # the context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.approve_comment(actor(moderator_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.approve_comment(actor(moderator_user_fixture()), "abc") ==
               {:error, :not_found}

      no_moderation_logs!()
    end
  end

  # A visible comment authored by a fresh user, ready to be destroyed.
  defp visible_comment(image) do
    comment_fixture(image, confirmed_user_fixture(), %{"body" => "Rule-breaking comment"})
  end

  # An already-hidden comment, set up through the log-free hide engine so no
  # moderation log exists before the destroy under test runs.
  defp already_hidden_comment(image) do
    {:ok, hidden} =
      Comments.hide_loaded_comment(
        visible_comment(image),
        %{"deletion_reason" => "Spam"},
        moderator_user_fixture()
      )

    hidden
  end

  describe "destroy_comment/2" do
    setup do
      %{image: image_fixture()}
    end

    test "denies an anonymous actor, leaving the body intact", %{image: image} do
      comment = visible_comment(image)

      assert Comments.destroy_comment(actor(), "#{comment.id}") == {:error, :unauthorized}

      reloaded = Repo.reload!(comment)
      assert reloaded.body == "Rule-breaking comment"
      refute reloaded.destroyed_content
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the body intact", %{image: image} do
      comment = visible_comment(image)

      assert Comments.destroy_comment(actor(confirmed_user_fixture()), "#{comment.id}") ==
               {:error, :unauthorized}

      reloaded = Repo.reload!(comment)
      assert reloaded.body == "Rule-breaking comment"
      refute reloaded.destroyed_content
      no_moderation_logs!()
    end

    test "a moderator destroys the comment, emptying its body", %{image: image} do
      comment = visible_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, %Comment{} = destroyed} =
               Comments.destroy_comment(actor(moderator), "#{comment.id}")

      assert destroyed.id == comment.id

      # The destroy engine blanks the body and marks the content destroyed; it
      # does not touch the comment's hidden/deletion_reason fields, so a visible
      # comment stays visible while its text is wiped.
      reloaded = Repo.reload!(comment)
      assert reloaded.body == ""
      assert reloaded.destroyed_content
      refute reloaded.hidden_from_users
      assert reloaded.deletion_reason == ""
    end

    # The engine authorizes :hide and never inspects hidden_from_users, so an
    # already-hidden comment is destroyable too; it keeps its hidden flag and
    # reason while the text is wiped.
    test "destroys an already-hidden comment, keeping its hidden flag and reason",
         %{image: image} do
      comment = already_hidden_comment(image)

      # Set up through the log-free engine, so no log exists before the destroy.
      no_moderation_logs!()

      assert {:ok, %Comment{}} =
               Comments.destroy_comment(actor(moderator_user_fixture()), "#{comment.id}")

      reloaded = Repo.reload!(comment)
      assert reloaded.body == ""
      assert reloaded.destroyed_content
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Spam"
    end

    test "the moderation log names the image and comment exactly", %{image: image} do
      comment = visible_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Comments.destroy_comment(actor(moderator), "#{comment.id}")

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Image.Comment.Delete:create"
      assert log.body == "Destroyed comment on image #{image.id}"
      assert log.subject_path == "/images/#{image.id}#comment_#{comment.id}"
    end

    test "destroying decrements the author's comments_count by one", %{image: image} do
      author = confirmed_user_fixture()
      comment = comment_fixture(image, author, %{"body" => "Rule-breaking comment"})
      before = Repo.get!(User, author.id).comments_count

      assert {:ok, _} = Comments.destroy_comment(actor(moderator_user_fixture()), "#{comment.id}")

      assert Repo.get!(User, author.id).comments_count == before - 1
    end

    # A well-formed id naming no row loads nil, which no :hide rule permits; the
    # context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.destroy_comment(actor(moderator_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.destroy_comment(actor(moderator_user_fixture()), "abc") ==
               {:error, :not_found}

      no_moderation_logs!()
    end
  end

  describe "hide_comment/3" do
    setup do
      %{image: image_fixture()}
    end

    test "denies an anonymous actor, leaving the comment visible", %{image: image} do
      comment = visible_comment(image)

      assert Comments.hide_comment(actor(), "#{comment.id}", %{"deletion_reason" => "Spam"}) ==
               {:error, :unauthorized}

      refute Repo.reload!(comment).hidden_from_users
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the comment visible", %{image: image} do
      comment = visible_comment(image)

      assert Comments.hide_comment(actor(confirmed_user_fixture()), "#{comment.id}", %{
               "deletion_reason" => "Spam"
             }) ==
               {:error, :unauthorized}

      reloaded = Repo.reload!(comment)
      refute reloaded.hidden_from_users
      assert reloaded.deletion_reason == ""
      no_moderation_logs!()
    end

    test "a moderator hides the comment with the given reason", %{image: image} do
      comment = visible_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, %Comment{} = hidden} =
               Comments.hide_comment(actor(moderator), "#{comment.id}", %{
                 "deletion_reason" => "Spam"
               })

      assert hidden.id == comment.id
      assert hidden.hidden_from_users
      assert hidden.deletion_reason == "Spam"

      reloaded = Repo.reload!(comment)
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Spam"
    end

    test "the moderation log names the image, comment, and reason exactly", %{image: image} do
      comment = visible_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, _} =
               Comments.hide_comment(actor(moderator), "#{comment.id}", %{
                 "deletion_reason" => "Spam"
               })

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Image.Comment.Hide:create"
      assert log.body == "Deleted comment on image #{image.id} (Spam)"
      assert log.subject_path == "/images/#{image.id}#comment_#{comment.id}"
    end

    test "a blank deletion reason is a rejected changeset carrying the loaded comment",
         %{image: image} do
      comment = visible_comment(image)

      assert {:error, %Comment{} = returned} =
               Comments.hide_comment(actor(moderator_user_fixture()), "#{comment.id}", %{
                 "deletion_reason" => ""
               })

      assert returned.id == comment.id
      refute Repo.reload!(comment).hidden_from_users
      no_moderation_logs!()
    end

    # A well-formed id naming no row loads nil, which no :hide rule permits; the
    # context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.hide_comment(actor(moderator_user_fixture()), "999999999", %{
               "deletion_reason" => "Spam"
             }) ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.hide_comment(actor(moderator_user_fixture()), "abc", %{
               "deletion_reason" => "Spam"
             }) ==
               {:error, :not_found}

      no_moderation_logs!()
    end
  end

  describe "unhide_comment/2" do
    setup do
      %{image: image_fixture()}
    end

    test "denies an anonymous actor, leaving the comment hidden", %{image: image} do
      comment = already_hidden_comment(image)

      assert Comments.unhide_comment(actor(), "#{comment.id}") == {:error, :unauthorized}
      assert Repo.reload!(comment).hidden_from_users
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the comment hidden", %{image: image} do
      comment = already_hidden_comment(image)

      assert Comments.unhide_comment(actor(confirmed_user_fixture()), "#{comment.id}") ==
               {:error, :unauthorized}

      reloaded = Repo.reload!(comment)
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Spam"
      no_moderation_logs!()
    end

    test "a moderator restores the comment, clearing its hidden flag and reason",
         %{image: image} do
      comment = already_hidden_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, %Comment{} = restored} =
               Comments.unhide_comment(actor(moderator), "#{comment.id}")

      assert restored.id == comment.id
      refute restored.hidden_from_users
      assert restored.deletion_reason == ""

      reloaded = Repo.reload!(comment)
      refute reloaded.hidden_from_users
      assert reloaded.deletion_reason == ""
    end

    test "the moderation log names the image and comment exactly", %{image: image} do
      comment = already_hidden_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Comments.unhide_comment(actor(moderator), "#{comment.id}")

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Image.Comment.Hide:delete"
      assert log.body == "Restored comment on image #{image.id}"
      assert log.subject_path == "/images/#{image.id}#comment_#{comment.id}"
    end

    # The restore is an unconditional column write, so restoring a comment that
    # is not hidden succeeds and still writes a log.
    test "restoring a non-hidden comment succeeds and logs", %{image: image} do
      comment = visible_comment(image)
      refute comment.hidden_from_users

      assert {:ok, %Comment{} = restored} =
               Comments.unhide_comment(actor(moderator_user_fixture()), "#{comment.id}")

      refute restored.hidden_from_users

      log = Repo.one!(ModerationLog)
      assert log.type == "Image.Comment.Hide:delete"
      assert log.body == "Restored comment on image #{image.id}"
    end

    # A well-formed id naming no row loads nil, which no :hide rule permits; the
    # context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.unhide_comment(actor(moderator_user_fixture()), "999999999") ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.unhide_comment(actor(moderator_user_fixture()), "abc") ==
               {:error, :not_found}

      no_moderation_logs!()
    end
  end

  describe "comment_history/3" do
    # A public read routed by image id and comment id. It writes no moderation
    # log and runs no ban check; it authorizes :show on the image and, for a
    # hidden comment, :show on the comment.

    setup do
      %{image: image_fixture()}
    end

    test "an anonymous actor reads the history of a visible comment", %{image: image} do
      comment = comment_fixture(image, confirmed_user_fixture(), %{"body" => "A visible comment"})

      assert {:ok, {loaded_image, %Comment{} = loaded_comment, versions}} =
               Comments.comment_history(actor(), "#{image.id}", "#{comment.id}")

      assert loaded_image.id == image.id
      assert loaded_comment.id == comment.id

      # The comment comes back with the associations the history page renders.
      assert %Philomena.Images.Image{} = loaded_comment.image
      assert %User{} = loaded_comment.user

      # A never-edited comment has recorded no versions.
      assert versions == []
    end

    test "an unknown image id is unauthorized" do
      assert Comments.comment_history(actor(), "999999999", "1") == {:error, :unauthorized}
    end

    test "an unknown comment id on a real image is not found", %{image: image} do
      assert Comments.comment_history(actor(), "#{image.id}", "999999999") == {:error, :not_found}
    end

    test "an anonymous actor cannot read the history of a hidden comment", %{image: image} do
      comment = already_hidden_comment(image)

      assert Comments.comment_history(actor(), "#{image.id}", "#{comment.id}") ==
               {:error, :unauthorized}
    end

    test "a regular user cannot read the history of a hidden comment", %{image: image} do
      comment = already_hidden_comment(image)

      assert Comments.comment_history(
               actor(confirmed_user_fixture()),
               "#{image.id}",
               "#{comment.id}"
             ) ==
               {:error, :unauthorized}
    end

    test "a moderator reads the history of a hidden comment", %{image: image} do
      comment = already_hidden_comment(image)

      assert {:ok, {_image, %Comment{} = loaded_comment, versions}} =
               Comments.comment_history(
                 actor(moderator_user_fixture()),
                 "#{image.id}",
                 "#{comment.id}"
               )

      assert loaded_comment.id == comment.id
      assert loaded_comment.hidden_from_users
      assert is_list(versions)
    end

    test "an edited comment reports the recorded version, its author, and the pre-edit body",
         %{image: image} do
      author = confirmed_user_fixture()
      comment = comment_fixture(image, author, %{"body" => "Original comment body"})

      {:ok, _} =
        Comments.update_comment(comment, author, %{
          "body" => "Original comment body plus an edit",
          "edit_reason" => "typo fix"
        })

      assert {:ok, {_image, _comment, [%CommentVersion{} = version]}} =
               Comments.comment_history(actor(), "#{image.id}", "#{comment.id}")

      # create_version records the body as it stood before the edit, so the
      # single version carries the original text and names its editor.
      assert version.body == "Original comment body"
      assert version.user.id == author.id
    end

    test "the history is capped at the most recent 25 versions", %{image: image} do
      author = confirmed_user_fixture()
      comment = comment_fixture(image, author, %{"body" => "edit 0"})

      # Each update records one version, so 26 edits record 26 versions; the
      # query limits the result to 25.
      Enum.reduce(1..26, comment, fn n, current ->
        {:ok, %{comment: updated}} =
          Comments.update_comment(current, author, %{"body" => "edit #{n}"})

        updated
      end)

      assert {:ok, {_image, _comment, versions}} =
               Comments.comment_history(actor(), "#{image.id}", "#{comment.id}")

      assert length(versions) == 25
    end
  end

  describe "load_commentable_image/3" do
    # Loads and per-action authorizes the image a comment listing or write hangs
    # off. It takes the current user (not an actor) and runs no ban check.

    test ":index on a visible image succeeds for an anonymous actor" do
      image = image_fixture()

      assert {:ok, %Image{} = loaded} =
               Comments.load_commentable_image(actor(), "#{image.id}", :index)

      assert loaded.id == image.id

      # The listing preloads are loaded on the returned image.
      assert is_list(loaded.tags)
      assert is_list(loaded.sources)
    end

    test ":show on a visible image succeeds for an anonymous actor" do
      image = image_fixture()

      assert {:ok, %Image{} = loaded} =
               Comments.load_commentable_image(actor(), "#{image.id}", :show)

      assert loaded.id == image.id
    end

    test ":show on a hidden image is unauthorized for a regular user" do
      image = image_fixture(%{hidden_from_users: true})

      assert Comments.load_commentable_image(
               actor(confirmed_user_fixture()),
               "#{image.id}",
               :show
             ) ==
               {:error, :unauthorized}
    end

    test ":create/:edit/:update require create_comment, rejecting a commenting-disabled image" do
      image = image_fixture(%{commenting_allowed: false})
      user = confirmed_user_fixture()

      for action <- [:create, :edit, :update] do
        assert Comments.load_commentable_image(actor(user), "#{image.id}", action) ==
                 {:error, :unauthorized}
      end
    end

    test ":create on a comment-enabled image succeeds for a regular user" do
      image = image_fixture()

      assert {:ok, %Image{} = loaded} =
               Comments.load_commentable_image(
                 actor(confirmed_user_fixture()),
                 "#{image.id}",
                 :create
               )

      assert loaded.id == image.id
    end

    # A well-formed id naming no row loads nil, which no rule permits; the
    # context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.load_commentable_image(actor(confirmed_user_fixture()), "999999999", :index) ==
               {:error, :unauthorized}
    end

    test "an id that cannot name a row is not found" do
      assert Comments.load_commentable_image(actor(confirmed_user_fixture()), "abc", :index) ==
               {:error, :not_found}
    end
  end

  describe "create_comment/3" do
    # A write taking an actor. It verifies write access first (ban -> :ban,
    # missing fingerprint -> :unauthorized); it does not itself authorize the
    # image, which the caller has already loaded and authorized.

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected", %{image: image} do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Comments.create_comment(actor, image, %{"body" => "Hi"}) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized, signed in or not", %{image: image} do
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert Comments.create_comment(signed_in, image, %{"body" => "Hi"}) ==
               {:error, :unauthorized}

      assert Comments.create_comment(anonymous, image, %{"body" => "Hi"}) ==
               {:error, :unauthorized}
    end

    test "a valid anonymous fingerprinted actor creates a comment with no author",
         %{image: image} do
      assert {:ok, %Comment{} = comment} =
               Comments.create_comment(actor(nil), image, %{"body" => "An anonymous comment"})

      assert comment.user_id == nil
      assert comment.body == "An anonymous comment"
      no_moderation_logs!()
    end

    test "a signed-in actor creates a comment attributed to the user", %{image: image} do
      user = confirmed_user_fixture()

      assert {:ok, %Comment{} = comment} =
               Comments.create_comment(actor(user), image, %{"body" => "A logged-in comment"})

      assert comment.user_id == user.id
      assert comment.body == "A logged-in comment"
      no_moderation_logs!()
    end

    test "an empty body is a creation failure, inserting nothing", %{image: image} do
      assert Comments.create_comment(actor(confirmed_user_fixture()), image, %{"body" => ""}) ==
               {:error, :creation_failed}

      # The insert and its image comment-count bump are rolled back together.
      assert Repo.get!(Image, image.id).comments_count == 0
    end

    test "an approved comment increments the author's comments_count by one", %{image: image} do
      author = confirmed_user_fixture()
      before = Repo.get!(User, author.id).comments_count

      assert {:ok, %Comment{} = comment} =
               Comments.create_comment(actor(author), image, %{"body" => "A trustworthy comment"})

      assert comment.approved
      assert Repo.get!(User, author.id).comments_count == before + 1
    end

    test "an over-limit actor is rate limited and no comment is created", %{image: image} do
      # The :comment_create counter is primed past the limit, so the rate check
      # (after write-access, before the insert) refuses the write.
      actor = actor(confirmed_user_fixture())
      exceed_rate_limit(actor, :comment_create)

      assert Comments.create_comment(actor, image, %{"body" => "Hi"}) == {:error, :rate_limited}

      # The comment and its image comment-count bump never happened.
      assert Repo.get!(Image, image.id).comments_count == 0
    end

    test "a successful create records the counter", %{image: image} do
      actor = actor(confirmed_user_fixture())
      track_rate_limit(actor, :comment_create)

      assert {:ok, %Comment{}} = Comments.create_comment(actor, image, %{"body" => "Hi"})
      assert rate_limit_count(actor, :comment_create) == "1"
    end

    test "the rate check precedes the insert: over-limit with a blank body is still rate limited",
         %{image: image} do
      # A blank body would fail the insert with :creation_failed, but the rate
      # check runs before create_loaded_comment, so the actor gets :rate_limited.
      actor = actor(confirmed_user_fixture())
      exceed_rate_limit(actor, :comment_create)

      assert Comments.create_comment(actor, image, %{"body" => ""}) == {:error, :rate_limited}
    end
  end

  describe "load_comment_for_show/2" do
    setup do
      %{image: image_fixture()}
    end

    test "returns a visible comment with display preloads", %{image: image} do
      comment = comment_fixture(image, confirmed_user_fixture(), %{"body" => "A visible comment"})

      assert {:ok, %Comment{} = loaded} = Comments.load_comment_for_show(image, "#{comment.id}")
      assert loaded.id == comment.id
      assert %User{} = loaded.user
    end

    test "returns a hidden comment too", %{image: image} do
      comment = already_hidden_comment(image)

      assert {:ok, %Comment{} = loaded} = Comments.load_comment_for_show(image, "#{comment.id}")
      assert loaded.id == comment.id
      assert loaded.hidden_from_users
    end

    test "an unknown comment id is not found", %{image: image} do
      assert Comments.load_comment_for_show(image, "999999999") == {:error, :not_found}
    end
  end

  describe "load_comment_for_edit/3" do
    # Backs the edit form (a GET-guarded action), so it runs the not-banned
    # check first (no fingerprint requirement) and then loads and authorizes the
    # comment for :edit.

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected", %{image: image} do
      comment = comment_fixture(image, confirmed_user_fixture())
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Comments.load_comment_for_edit(actor, image, "#{comment.id}") == {:error, :ban}
    end

    test "the author loads the form", %{image: image} do
      author = confirmed_user_fixture()
      comment = comment_fixture(image, author, %{"body" => "My comment"})

      assert {:ok, {%Comment{} = loaded, %Ecto.Changeset{} = changeset}} =
               Comments.load_comment_for_edit(actor(author), image, "#{comment.id}")

      assert loaded.id == comment.id

      # The changeset is over the loaded comment, driving the edit form.
      assert %Comment{} = changeset.data
      assert changeset.data.id == comment.id
    end

    test "another regular user cannot load the form", %{image: image} do
      comment = comment_fixture(image, confirmed_user_fixture())

      assert Comments.load_comment_for_edit(
               actor(confirmed_user_fixture()),
               image,
               "#{comment.id}"
             ) ==
               {:error, :unauthorized}
    end

    test "a moderator loads the form", %{image: image} do
      comment = comment_fixture(image, confirmed_user_fixture())

      assert {:ok, {%Comment{} = loaded, %Ecto.Changeset{}}} =
               Comments.load_comment_for_edit(
                 actor(moderator_user_fixture()),
                 image,
                 "#{comment.id}"
               )

      assert loaded.id == comment.id
    end

    test "an unknown comment id is not found", %{image: image} do
      assert Comments.load_comment_for_edit(
               actor(confirmed_user_fixture()),
               image,
               "999999999"
             ) ==
               {:error, :not_found}
    end
  end

  describe "update_comment/4" do
    # A write, so it runs the write-access check first (ban -> :ban), then the
    # same load-and-authorize chain as the edit form, then the edit engine which
    # records a version.

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected", %{image: image} do
      comment = comment_fixture(image, confirmed_user_fixture())
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Comments.update_comment(actor, image, "#{comment.id}", %{"body" => "Edited"}) ==
               {:error, :ban}
    end

    test "the author edits the body and the comment is marked edited", %{image: image} do
      author = confirmed_user_fixture()
      comment = comment_fixture(image, author, %{"body" => "Original comment body"})

      assert {:ok, %Comment{} = updated} =
               Comments.update_comment(actor(author), image, "#{comment.id}", %{
                 "body" => "Original comment body plus an edit",
                 "edit_reason" => "typo"
               })

      assert updated.body == "Original comment body plus an edit"
      assert updated.edited_at != nil

      reloaded = Repo.reload!(comment)
      assert reloaded.body == "Original comment body plus an edit"
      assert reloaded.edited_at != nil
      no_moderation_logs!()
    end

    test "another regular user cannot edit, leaving the body unchanged", %{image: image} do
      comment =
        comment_fixture(image, confirmed_user_fixture(), %{"body" => "Original comment body"})

      assert Comments.update_comment(
               actor(confirmed_user_fixture()),
               image,
               "#{comment.id}",
               %{"body" => "Hijacked"}
             ) ==
               {:error, :unauthorized}

      assert Repo.reload!(comment).body == "Original comment body"
    end

    test "a blank body is a rejected changeset carrying the loaded comment", %{image: image} do
      author = confirmed_user_fixture()
      comment = comment_fixture(image, author, %{"body" => "Original comment body"})

      assert {:error, {%Comment{} = returned, %Ecto.Changeset{}}} =
               Comments.update_comment(actor(author), image, "#{comment.id}", %{"body" => ""})

      assert returned.id == comment.id
      assert Repo.reload!(comment).body == "Original comment body"
    end

    test "an unknown comment id is not found", %{image: image} do
      assert Comments.update_comment(
               actor(confirmed_user_fixture()),
               image,
               "999999999",
               %{"body" => "Edited"}
             ) ==
               {:error, :not_found}
    end
  end

  describe "load_comment_for_report/3" do
    # Backs the report form (a GET-guarded action), so it runs the not-banned
    # check first (no fingerprint requirement) and then authorizes the image for
    # :show and loads the comment within it (a hidden comment visible only to
    # actors who may :show it).

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected before any loading, even with garbage ids" do
      # verify_not_banned runs before the loader, so a banned actor is
      # {:error, :ban} even against ids that could never load.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Comments.load_comment_for_report(actor, "999999999", "abc") == {:error, :ban}
    end

    test "an anonymous actor loads the report form for a visible comment", %{image: image} do
      comment = comment_fixture(image, confirmed_user_fixture(), %{"body" => "A visible comment"})

      assert {:ok, {%Comment{} = loaded, %Ecto.Changeset{} = changeset}} =
               Comments.load_comment_for_report(actor(nil), "#{image.id}", "#{comment.id}")

      assert loaded.id == comment.id

      # The comment carries its image preloaded for building the form action.
      assert %Image{} = loaded.image

      # The changeset is over a Report addressed at this comment.
      assert %Report{} = changeset.data
      assert changeset.data.comment_id == comment.id
    end

    test "a regular user cannot load a hidden comment's report form", %{image: image} do
      comment = already_hidden_comment(image)

      assert Comments.load_comment_for_report(
               actor(confirmed_user_fixture()),
               "#{image.id}",
               "#{comment.id}"
             ) ==
               {:error, :unauthorized}
    end

    test "a moderator loads a hidden comment's report form", %{image: image} do
      comment = already_hidden_comment(image)

      assert {:ok, {%Comment{} = loaded, %Ecto.Changeset{}}} =
               Comments.load_comment_for_report(
                 actor(moderator_user_fixture()),
                 "#{image.id}",
                 "#{comment.id}"
               )

      assert loaded.id == comment.id
      assert loaded.hidden_from_users
    end

    test "an unknown comment id is not found", %{image: image} do
      assert Comments.load_comment_for_report(actor(nil), "#{image.id}", "999999999") ==
               {:error, :not_found}
    end

    test "an unknown image id is unauthorized" do
      assert Comments.load_comment_for_report(actor(nil), "999999999", "1") ==
               {:error, :unauthorized}
    end

    test "a non-castable image id is not found" do
      assert Comments.load_comment_for_report(actor(nil), "abc", "1") == {:error, :not_found}
    end
  end

  describe "load_comment_for_report_creation/3" do
    # Backs the report submission (a write), so it runs the write-access check
    # first (ban -> :ban, missing fingerprint -> :unauthorized) and then the same
    # image/comment load-and-authorize chain as the report form.

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected before any loading, even with garbage ids" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Comments.load_comment_for_report_creation(actor, "999999999", "abc") ==
               {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading, signed in or not" do
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert Comments.load_comment_for_report_creation(signed_in, "999999999", "abc") ==
               {:error, :unauthorized}

      assert Comments.load_comment_for_report_creation(anonymous, "999999999", "abc") ==
               {:error, :unauthorized}
    end

    test "a valid anonymous fingerprinted actor loads a visible comment", %{image: image} do
      # actor(nil) carries the shared fingerprint, so it clears the write-access
      # check and reaches the image/comment load.
      comment = comment_fixture(image, confirmed_user_fixture(), %{"body" => "A visible comment"})

      assert {:ok, %Comment{} = loaded} =
               Comments.load_comment_for_report_creation(
                 actor(nil),
                 "#{image.id}",
                 "#{comment.id}"
               )

      assert loaded.id == comment.id
      assert %Image{} = loaded.image
    end

    test "a regular user cannot load a hidden comment", %{image: image} do
      comment = already_hidden_comment(image)

      assert Comments.load_comment_for_report_creation(
               actor(confirmed_user_fixture()),
               "#{image.id}",
               "#{comment.id}"
             ) ==
               {:error, :unauthorized}
    end

    test "a moderator loads a hidden comment", %{image: image} do
      comment = already_hidden_comment(image)

      assert {:ok, %Comment{} = loaded} =
               Comments.load_comment_for_report_creation(
                 actor(moderator_user_fixture()),
                 "#{image.id}",
                 "#{comment.id}"
               )

      assert loaded.id == comment.id
      assert loaded.hidden_from_users
    end

    test "an unknown comment id is not found", %{image: image} do
      assert Comments.load_comment_for_report_creation(
               actor(confirmed_user_fixture()),
               "#{image.id}",
               "999999999"
             ) ==
               {:error, :not_found}
    end

    test "an unknown image id is unauthorized" do
      assert Comments.load_comment_for_report_creation(
               actor(confirmed_user_fixture()),
               "999999999",
               "1"
             ) ==
               {:error, :unauthorized}
    end

    test "a non-castable image id is not found" do
      assert Comments.load_comment_for_report_creation(
               actor(confirmed_user_fixture()),
               "abc",
               "1"
             ) ==
               {:error, :not_found}
    end
  end

  # Pulls the must_not exclusion list out of an unexecuted comment search
  # definition.
  defp must_not(definition), do: definition.body.query.bool.must_not

  describe "comment_search_definition/4" do
    test "an anonymous viewer excludes deleted, non-approved, and hidden-tag comments" do
      filter = %Filter{hidden_tag_ids: [7, 8]}
      definition = Comments.comment_search_definition(nil, filter, %{match_all: %{}})

      assert definition.module == Comment
      assert definition.body.query.bool.must == %{match_all: %{}}
      assert definition.body.sort == %{created_at: :desc}

      filters = must_not(definition)
      assert %{term: %{approved: false}} in filters
      assert %{term: %{"image.approved" => false}} in filters
      assert %{term: %{hidden_from_users: true}} in filters
      assert %{term: %{"image.hidden_from_users" => true}} in filters
      assert %{terms: %{"image.tag_ids" => [7, 8]}} in filters
    end

    test "a signed-in non-staff viewer scopes the approved exception to their own id" do
      user = confirmed_user_fixture()

      filters =
        must_not(Comments.comment_search_definition(user, @empty_filter, %{match_all: %{}}))

      # The plain approved/image.approved excludes are replaced by a should-clause
      # that keeps the viewer's own non-approved comments.
      should = [%{term: %{approved: false}}, %{term: %{"image.approved" => false}}]

      assert %{bool: %{should: should, must_not: [%{term: %{user_id: user.id}}]}} in filters
      refute %{term: %{approved: false}} in filters

      # The deleted and hidden-tag excludes still apply.
      assert %{term: %{hidden_from_users: true}} in filters
    end

    test "a staff viewer drops the deleted and non-approved excludes by default" do
      moderator = moderator_user_fixture()
      filter = %Filter{hidden_tag_ids: [7]}
      filters = must_not(Comments.comment_search_definition(moderator, filter, %{match_all: %{}}))

      assert filters == [%{terms: %{"image.tag_ids" => [7]}}]
    end

    test "a staff viewer with show_hidden false keeps the deleted and non-approved excludes" do
      moderator = moderator_user_fixture()

      filters =
        must_not(
          Comments.comment_search_definition(
            moderator,
            @empty_filter,
            %{match_all: %{}},
            show_hidden: false
          )
        )

      # With show_hidden disabled a staff viewer is filtered like a signed-in
      # non-staff user, so the own-comments exception is scoped to their id.
      should = [%{term: %{approved: false}}, %{term: %{"image.approved" => false}}]

      assert %{bool: %{should: should, must_not: [%{term: %{user_id: moderator.id}}]}} in filters
      assert %{term: %{hidden_from_users: true}} in filters
    end

    test "passes pagination through to the search window" do
      definition =
        Comments.comment_search_definition(
          nil,
          @empty_filter,
          %{match_all: %{}},
          pagination: %{page_number: 3, page_size: 10}
        )

      assert definition.page_number == 3
      assert definition.page_size == 10
      assert definition.body.from == 20
      assert definition.body.size == 10
    end
  end

  # Creates an approved comment on `image`, its created_at fixed to a distinct
  # second so listing order is deterministic under the second-precision column.
  defp comment_at(image, offset) do
    comment_fixture(image, confirmed_user_fixture(), %{"body" => "Comment #{offset}"})
    |> Ecto.Changeset.change(created_at: DateTime.add(~U[2024-01-01 00:00:00Z], offset, :second))
    |> Repo.update!()
  end

  defp pending_comment(image, user \\ nil) do
    comment_fixture(image, user || confirmed_user_fixture())
    |> Ecto.Changeset.change(approved: false)
    |> Repo.update!()
  end

  defp destroyed_comment(image) do
    comment_fixture(image, confirmed_user_fixture())
    |> Ecto.Changeset.change(destroyed_content: true)
    |> Repo.update!()
  end

  defp oldest_first_user do
    user = confirmed_user_fixture()

    settings =
      user.settings
      |> Ecto.Changeset.change(comments_newest_first: false)
      |> Repo.update!()

    %{user | settings: settings}
  end

  describe "paginate_image_comments/3" do
    setup do
      %{image: image_fixture()}
    end

    test "returns a Scrivener page ordered newest first by default", %{image: image} do
      c1 = comment_at(image, 1)
      c2 = comment_at(image, 2)
      c3 = comment_at(image, 3)

      page = Comments.paginate_image_comments(actor(nil), image, page: 1, page_size: 25)

      assert %Scrivener.Page{} = page
      assert Enum.map(page.entries, & &1.id) == [c3.id, c2.id, c1.id]
    end

    test "orders oldest first for a user who reads oldest first", %{image: image} do
      c1 = comment_at(image, 1)
      c2 = comment_at(image, 2)
      c3 = comment_at(image, 3)

      page =
        Comments.paginate_image_comments(actor(oldest_first_user()), image,
          page: 1,
          page_size: 25
        )

      assert Enum.map(page.entries, & &1.id) == [c1.id, c2.id, c3.id]
    end

    test "an anonymous viewer sees only approved, non-destroyed comments", %{image: image} do
      approved = comment_fixture(image, confirmed_user_fixture())
      _pending = pending_comment(image)
      _destroyed = destroyed_comment(image)

      page = Comments.paginate_image_comments(actor(nil), image, page: 1, page_size: 25)

      assert Enum.map(page.entries, & &1.id) == [approved.id]
    end

    test "a signed-in non-staff user additionally sees their own non-approved comments",
         %{image: image} do
      author = confirmed_user_fixture()
      approved = comment_fixture(image, confirmed_user_fixture())
      own_pending = pending_comment(image, author)
      others_pending = pending_comment(image)

      page = Comments.paginate_image_comments(actor(author), image, page: 1, page_size: 25)
      ids = Enum.map(page.entries, & &1.id)

      assert approved.id in ids
      assert own_pending.id in ids
      refute others_pending.id in ids
    end

    test "staff see destroyed and non-approved comments", %{image: image} do
      approved = comment_fixture(image, confirmed_user_fixture())
      pending = pending_comment(image)
      destroyed = destroyed_comment(image)

      page =
        Comments.paginate_image_comments(actor(moderator_user_fixture()), image,
          page: 1,
          page_size: 25
        )

      ids = Enum.map(page.entries, & &1.id)

      assert approved.id in ids
      assert pending.id in ids
      assert destroyed.id in ids
    end
  end

  describe "find_comment_page/4" do
    setup do
      image = image_fixture()

      %{
        image: image,
        c1: comment_at(image, 1),
        c2: comment_at(image, 2),
        c3: comment_at(image, 3)
      }
    end

    test "returns the page a comment falls on for a newest-first reader",
         %{image: image, c1: c1, c2: c2, c3: c3} do
      # Newest first, page size 2: c3 and c2 share page 1, c1 falls to page 2.
      assert Comments.find_comment_page(actor(), image, c3.id, page_size: 2) == 1
      assert Comments.find_comment_page(actor(), image, c2.id, page_size: 2) == 1
      assert Comments.find_comment_page(actor(), image, c1.id, page_size: 2) == 2
    end

    test "honors an oldest-first reader's direction", %{image: image, c1: c1, c2: c2, c3: c3} do
      user = oldest_first_user()

      # Oldest first, page size 2: c1 and c2 share page 1, c3 falls to page 2.
      assert Comments.find_comment_page(actor(user), image, c1.id, page_size: 2) == 1
      assert Comments.find_comment_page(actor(user), image, c2.id, page_size: 2) == 1
      assert Comments.find_comment_page(actor(user), image, c3.id, page_size: 2) == 2
    end

    test "raises when the comment does not belong to the image", %{image: image} do
      foreign = comment_fixture(image_fixture(), confirmed_user_fixture())

      assert_raise Ecto.NoResultsError, fn ->
        Comments.find_comment_page(actor(), image, foreign.id, page_size: 2)
      end
    end
  end

  describe "last_comment_page/3" do
    test "returns the last page of a populated listing" do
      image = image_fixture()
      for offset <- 1..3, do: comment_at(image, offset)

      assert Comments.last_comment_page(nil, image, page_size: 2) == 2
    end

    test "returns page 1 for an empty listing" do
      assert Comments.last_comment_page(nil, image_fixture(), page_size: 2) == 1
    end

    test "counts only the comments visible to the viewer" do
      image = image_fixture()
      comment_fixture(image, confirmed_user_fixture())
      pending_comment(image)

      # The anonymous viewer does not count the non-approved comment, so it
      # lands a page earlier than staff, who count both.
      assert Comments.last_comment_page(nil, image, page_size: 1) == 2
      assert Comments.last_comment_page(moderator_user_fixture(), image, page_size: 1) == 3
    end
  end
end
