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

  import Philomena.CommentsFixtures
  import Philomena.ImagesFixtures
  import Philomena.ReportsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Comments
  alias Philomena.Filters.Filter
  alias Philomena.Repo
  alias Philomena.Comments.Comment
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Reports.Report
  alias Philomena.Users.User
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

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
                 nil,
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
               Comments.search_comments(nil, @empty_filter, "grapefruit", @pagination)

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
               Comments.search_comments(nil, @empty_filter, "grapefruit", @pagination)

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
               Comments.search_comments(moderator, @empty_filter, "grapefruit", @pagination)

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
               Comments.search_comments(nil, hidden_filter, "grapefruit", @pagination)

      assert results.entries == []

      # The same comment is visible when the tag is not hidden.
      assert {:ok, results} =
               Comments.search_comments(nil, @empty_filter, "grapefruit", @pagination)

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

      assert Comments.approve_comment(nil, "#{comment.id}") == {:error, :unauthorized}
      refute Repo.reload!(comment).approved
      no_moderation_logs!()
    end

    test "denies a regular user", %{image: image} do
      {comment, _author} = unapproved_comment(image)

      assert Comments.approve_comment(confirmed_user_fixture(), "#{comment.id}") ==
               {:error, :unauthorized}

      refute Repo.reload!(comment).approved
      no_moderation_logs!()
    end

    test "a moderator approves the comment, which is returned approved", %{image: image} do
      {comment, _author} = unapproved_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, %Comment{} = approved} = Comments.approve_comment(moderator, "#{comment.id}")

      assert approved.id == comment.id
      assert approved.approved

      assert Repo.reload!(comment).approved
    end

    test "the moderation log names the image and comment exactly", %{image: image} do
      {comment, _author} = unapproved_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Comments.approve_comment(moderator, "#{comment.id}")

      log = Repo.one!(ModerationLog)
      assert log.user_id == moderator.id
      assert log.type == "Image.Comment.Approve:create"
      assert log.body == "Approved comment on image #{image.id}"
      assert log.subject_path == "/images/#{image.id}#comment_#{comment.id}"
    end

    test "approving increments the author's comments_count by one", %{image: image} do
      {comment, author} = unapproved_comment(image)
      before = Repo.get!(User, author.id).comments_count

      assert {:ok, _} = Comments.approve_comment(moderator_user_fixture(), "#{comment.id}")

      assert Repo.get!(User, author.id).comments_count == before + 1
    end

    test "approving closes the comment's open reports", %{image: image} do
      {comment, _author} = unapproved_comment(image)
      report = report_fixture({"Comment", comment.id}, confirmed_user_fixture())

      assert report.open
      assert report.state == "open"

      assert {:ok, _} = Comments.approve_comment(moderator_user_fixture(), "#{comment.id}")

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
               Comments.approve_comment(moderator_user_fixture(), "#{comment.id}")

      assert approved.approved
      assert Repo.get!(User, author.id).comments_count == before + 1

      log = Repo.one!(ModerationLog)
      assert log.type == "Image.Comment.Approve:create"
      assert log.body == "Approved comment on image #{image.id}"
    end

    # A well-formed id naming no row loads nil, which no :approve rule permits;
    # the context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.approve_comment(moderator_user_fixture(), "999999999") ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.approve_comment(moderator_user_fixture(), "abc") == {:error, :not_found}
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

      assert Comments.destroy_comment(nil, "#{comment.id}") == {:error, :unauthorized}

      reloaded = Repo.reload!(comment)
      assert reloaded.body == "Rule-breaking comment"
      refute reloaded.destroyed_content
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the body intact", %{image: image} do
      comment = visible_comment(image)

      assert Comments.destroy_comment(confirmed_user_fixture(), "#{comment.id}") ==
               {:error, :unauthorized}

      reloaded = Repo.reload!(comment)
      assert reloaded.body == "Rule-breaking comment"
      refute reloaded.destroyed_content
      no_moderation_logs!()
    end

    test "a moderator destroys the comment, emptying its body", %{image: image} do
      comment = visible_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, %Comment{} = destroyed} = Comments.destroy_comment(moderator, "#{comment.id}")

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
               Comments.destroy_comment(moderator_user_fixture(), "#{comment.id}")

      reloaded = Repo.reload!(comment)
      assert reloaded.body == ""
      assert reloaded.destroyed_content
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Spam"
    end

    test "the moderation log names the image and comment exactly", %{image: image} do
      comment = visible_comment(image)
      moderator = moderator_user_fixture()

      assert {:ok, _} = Comments.destroy_comment(moderator, "#{comment.id}")

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

      assert {:ok, _} = Comments.destroy_comment(moderator_user_fixture(), "#{comment.id}")

      assert Repo.get!(User, author.id).comments_count == before - 1
    end

    # A well-formed id naming no row loads nil, which no :hide rule permits; the
    # context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.destroy_comment(moderator_user_fixture(), "999999999") ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.destroy_comment(moderator_user_fixture(), "abc") == {:error, :not_found}
      no_moderation_logs!()
    end
  end

  describe "hide_comment/3" do
    setup do
      %{image: image_fixture()}
    end

    test "denies an anonymous actor, leaving the comment visible", %{image: image} do
      comment = visible_comment(image)

      assert Comments.hide_comment(nil, "#{comment.id}", %{"deletion_reason" => "Spam"}) ==
               {:error, :unauthorized}

      refute Repo.reload!(comment).hidden_from_users
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the comment visible", %{image: image} do
      comment = visible_comment(image)

      assert Comments.hide_comment(confirmed_user_fixture(), "#{comment.id}", %{
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
               Comments.hide_comment(moderator, "#{comment.id}", %{"deletion_reason" => "Spam"})

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
               Comments.hide_comment(moderator, "#{comment.id}", %{"deletion_reason" => "Spam"})

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
               Comments.hide_comment(moderator_user_fixture(), "#{comment.id}", %{
                 "deletion_reason" => ""
               })

      assert returned.id == comment.id
      refute Repo.reload!(comment).hidden_from_users
      no_moderation_logs!()
    end

    # A well-formed id naming no row loads nil, which no :hide rule permits; the
    # context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.hide_comment(moderator_user_fixture(), "999999999", %{
               "deletion_reason" => "Spam"
             }) ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.hide_comment(moderator_user_fixture(), "abc", %{"deletion_reason" => "Spam"}) ==
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

      assert Comments.unhide_comment(nil, "#{comment.id}") == {:error, :unauthorized}
      assert Repo.reload!(comment).hidden_from_users
      no_moderation_logs!()
    end

    test "denies a regular user, leaving the comment hidden", %{image: image} do
      comment = already_hidden_comment(image)

      assert Comments.unhide_comment(confirmed_user_fixture(), "#{comment.id}") ==
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

      assert {:ok, %Comment{} = restored} = Comments.unhide_comment(moderator, "#{comment.id}")

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

      assert {:ok, _} = Comments.unhide_comment(moderator, "#{comment.id}")

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
               Comments.unhide_comment(moderator_user_fixture(), "#{comment.id}")

      refute restored.hidden_from_users

      log = Repo.one!(ModerationLog)
      assert log.type == "Image.Comment.Hide:delete"
      assert log.body == "Restored comment on image #{image.id}"
    end

    # A well-formed id naming no row loads nil, which no :hide rule permits; the
    # context returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Comments.unhide_comment(moderator_user_fixture(), "999999999") ==
               {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an id that cannot name a row is not found" do
      assert Comments.unhide_comment(moderator_user_fixture(), "abc") == {:error, :not_found}
      no_moderation_logs!()
    end
  end
end
