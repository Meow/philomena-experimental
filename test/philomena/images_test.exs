defmodule Philomena.ImagesTest do
  use Philomena.DataCase, async: true

  import Ecto.Query

  alias Philomena.ImageFaves
  alias Philomena.ImageFaves.ImageFave
  alias Philomena.ImageFeatures.ImageFeature
  alias Philomena.ImageHides
  alias Philomena.ImageHides.ImageHide
  alias Philomena.Images
  alias Philomena.ImageVotes
  alias Philomena.ImageVotes.ImageVote
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Notifications
  alias Philomena.Notifications.ImageCommentNotification
  alias Philomena.Notifications.ImageMergeNotification
  alias Philomena.SourceChanges.SourceChange
  alias Philomena.TagChanges.Limits
  alias Philomena.TagChanges.TagChange
  alias Philomena.Images.Image
  alias Philomena.Images.ImagePage
  alias Philomena.Images.Search.Scope
  alias Philomena.Galleries
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures
  import Philomena.AttributionFixtures
  import Philomena.CommentsFixtures
  import Philomena.GalleriesFixtures

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to verify_write_access.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }
  import Philomena.SourceChangesFixtures

  defp comment_notification?(image, user) do
    Repo.exists?(
      from n in ImageCommentNotification,
        where: n.image_id == ^image.id and n.user_id == ^user.id
    )
  end

  defp merge_notification?(image, user) do
    Repo.exists?(
      from n in ImageMergeNotification,
        where: n.target_id == ^image.id and n.user_id == ^user.id
    )
  end

  # Arranges a real unread image comment notification for `user`: subscribe the
  # user to the image, then have another user comment so a notification lands.
  defp arrange_comment_notification(image, user) do
    author = confirmed_user_fixture()
    {:ok, _} = Images.create_subscription(image, user)
    comment = comment_fixture(image, author)
    {:ok, _} = Notifications.create_image_comment_notification(author, image, comment)
    :ok
  end

  # Arranges a real unread image merge notification for `user`: subscribe the
  # user to the target image, then merge a source image into it.
  defp arrange_merge_notification(image, user) do
    source = image_fixture()
    {:ok, _} = Images.create_subscription(image, user)
    {:ok, _} = Notifications.create_image_merge_notification(image, source)
    :ok
  end

  defp only_moderation_log!, do: Repo.one!(ModerationLog)

  defp moderation_log_count, do: Repo.aggregate(ModerationLog, :count)

  defp source_change_count(image) do
    Repo.aggregate(from(s in SourceChange, where: s.image_id == ^image.id), :count)
  end

  defp fave!(image, user) do
    {:ok, _} = Repo.transaction(ImageFaves.create_fave_transaction(image, user))
  end

  defp vote!(image, user, up) do
    {:ok, _} = Repo.transaction(ImageVotes.create_vote_transaction(image, user, up))
  end

  defp hide!(image, user) do
    {:ok, _} = Repo.transaction(ImageHides.create_hide_transaction(image, user))
  end

  defp has_vote?(image, user) do
    Repo.exists?(from v in ImageVote, where: v.image_id == ^image.id and v.user_id == ^user.id)
  end

  defp image_hide_count(image, user) do
    Repo.aggregate(
      from(h in ImageHide, where: h.image_id == ^image.id and h.user_id == ^user.id),
      :count
    )
  end

  defp fave_count(image, user) do
    Repo.aggregate(
      from(f in ImageFave, where: f.image_id == ^image.id and f.user_id == ^user.id),
      :count
    )
  end

  defp vote_row(image, user) do
    Repo.get_by(ImageVote, image_id: image.id, user_id: user.id)
  end

  defp source_change_row_count(image) do
    Repo.aggregate(from(s in SourceChange, where: s.image_id == ^image.id), :count)
  end

  # Controller-shaped attrs adding a single source with no prior sources.
  defp add_source_attrs(url) do
    %{"old_sources" => %{}, "sources" => %{"0" => %{"source" => url}}}
  end

  defp tag_names(image) do
    image
    |> Repo.preload(:tags, force: true)
    |> Map.fetch!(:tags)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp tag_attrs(old_tag_input, tag_input) do
    %{"old_tag_input" => old_tag_input, "tag_input" => tag_input}
  end

  # Controller-shaped attrs adding `count` distinct sources.
  defp many_source_attrs(count) do
    sources =
      Map.new(0..(count - 1), fn i ->
        {to_string(i), %{"source" => "https://example.com/#{i}"}}
      end)

    %{"old_sources" => %{}, "sources" => sources}
  end

  # Hides an image through the internal engine (which writes no moderation log),
  # so a later log assertion sees only the row the function under test creates.
  defp hidden_image_fixture(reason \\ "Original reason") do
    image = image_fixture()

    {:ok, %{image: hidden}} =
      Images.hide_loaded_image(image, moderator_user_fixture(), %{"deletion_reason" => reason})

    hidden
  end

  defp feature_row_count(image) do
    Repo.aggregate(from(f in ImageFeature, where: f.image_id == ^image.id), :count)
  end

  defp locked_tag_names(image) do
    image
    |> Repo.reload!()
    |> Repo.preload(:locked_tags)
    |> Map.fetch!(:locked_tags)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  describe "create_image/2 duplicate detection" do
    # image_changeset's prepare_changes rejects a new upload whose
    # image_orig_sha512_hash already belongs to another image. On INSERT the
    # changeset's data.id is nil, so the self-exclusion added to fix the file
    # replacement bug never applies here - a genuine duplicate is still a
    # duplicate. create_image surfaces the changeset error as the raw Multi
    # failure tuple {:error, :image, changeset, changes}.
    test "rejects a new upload whose file duplicates an existing image's hash" do
      existing = image_fixture(image_orig_sha512_hash: png_upload_sha512())
      user = user_fixture()

      attrs = %{"image" => png_upload(), "tag_input" => "safe, solo, mare"}

      assert {:error, :image, changeset, _changes} =
               Images.create_image(attribution(user), attrs)

      assert "has already been uploaded: it's image #{existing.id}" in errors_on(changeset).image
    end
  end

  describe "update_file/2 duplicate detection" do
    # Root cause of the fixed bug: replacing an image's file with a
    # byte-identical copy. The image's own row still holds that file's
    # orig_sha512_hash, so the dedup lookup matches the image against itself;
    # the self-exclusion (other_image.id == changeset.data.id) lets it through
    # instead of raising a spurious "already been uploaded" error. The old code
    # sidestepped this by nulling the hash first; now no nulling is needed.
    test "allows replacing a file with a byte-identical copy of the image's own file" do
      sha = png_upload_sha512()
      image = image_fixture(image_sha512_hash: sha, image_orig_sha512_hash: sha)

      assert {:ok, updated} = Images.update_file(image, %{"image" => png_upload()})

      # The dedup fingerprint is still set - it is overwritten with the (same)
      # new file's hash, never nulled.
      assert updated.image_orig_sha512_hash == sha
    end

    # A file matching a *different* image is still rejected - the self-exclusion
    # only spares the image being updated, not genuine cross-image duplicates.
    # update_file returns the changeset error tuple unchanged.
    test "rejects replacing a file with one already uploaded as another image" do
      dup_sha = png_upload_sha512()
      other = image_fixture(image_sha512_hash: dup_sha, image_orig_sha512_hash: dup_sha)
      image = image_fixture()

      assert {:error, changeset} = Images.update_file(image, %{"image" => png_upload()})

      assert "has already been uploaded: it's image #{other.id}" in errors_on(changeset).image
      # The target image keeps its own fingerprint.
      assert Repo.reload!(image).image_orig_sha512_hash == image.image_orig_sha512_hash
    end
  end

  describe "mark_image_read/2" do
    test "clears the actor's image comment notification and returns the image" do
      user = confirmed_user_fixture()
      image = image_fixture()
      arrange_comment_notification(image, user)
      assert comment_notification?(image, user)

      assert {:ok, marked} = Images.mark_image_read(user, to_string(image.id))
      assert marked.id == image.id
      refute comment_notification?(image, user)
    end

    test "clears the actor's image merge notification and returns the image" do
      user = confirmed_user_fixture()
      image = image_fixture()
      arrange_merge_notification(image, user)
      assert merge_notification?(image, user)

      assert {:ok, marked} = Images.mark_image_read(user, to_string(image.id))
      assert marked.id == image.id
      refute merge_notification?(image, user)
    end

    test "clears both comment and merge notifications at once" do
      user = confirmed_user_fixture()
      image = image_fixture()
      arrange_comment_notification(image, user)
      arrange_merge_notification(image, user)
      assert comment_notification?(image, user)
      assert merge_notification?(image, user)

      assert {:ok, marked} = Images.mark_image_read(user, to_string(image.id))
      assert marked.id == image.id
      refute comment_notification?(image, user)
      refute merge_notification?(image, user)
    end

    test "clears only the actor's notifications, leaving another user's intact" do
      # clear_image_notification filters on the actor's user_id, so a second
      # subscriber's notification for the same image is untouched.
      user = confirmed_user_fixture()
      other = confirmed_user_fixture()
      image = image_fixture()
      arrange_comment_notification(image, user)
      arrange_comment_notification(image, other)
      assert comment_notification?(image, user)
      assert comment_notification?(image, other)

      assert {:ok, _} = Images.mark_image_read(user, to_string(image.id))
      refute comment_notification?(image, user)
      assert comment_notification?(image, other)
    end

    test "succeeds with no notifications to clear" do
      user = confirmed_user_fixture()
      image = image_fixture()
      refute comment_notification?(image, user)
      refute merge_notification?(image, user)

      assert {:ok, marked} = Images.mark_image_read(user, to_string(image.id))
      assert marked.id == image.id
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, marked} = Images.mark_image_read(user, image.id)
      assert marked.id == image.id
    end

    test "an unknown well-formed id is not found" do
      user = confirmed_user_fixture()

      assert Images.mark_image_read(user, "2147483647") == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      user = confirmed_user_fixture()

      assert Images.mark_image_read(user, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, so it is a plain not found rather than a crash.
      user = confirmed_user_fixture()

      assert Images.mark_image_read(user, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "remove_image_hash/2" do
    test "a moderator clears the hash and gets the updated image" do
      moderator = moderator_user_fixture()
      image = image_fixture()
      assert image.image_orig_sha512_hash != nil

      assert {:ok, cleared} = Images.remove_image_hash(moderator, to_string(image.id))
      assert cleared.id == image.id
      assert cleared.image_orig_sha512_hash == nil
      assert Repo.reload!(image).image_orig_sha512_hash == nil
    end

    test "an admin clears the hash" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, cleared} = Images.remove_image_hash(admin, to_string(image.id))
      assert cleared.id == image.id
      assert Repo.reload!(image).image_orig_sha512_hash == nil
    end

    test "a regular user cannot clear the hash and it stays set" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.remove_image_hash(user, to_string(image.id)) == {:error, :unauthorized}
      assert Repo.reload!(image).image_orig_sha512_hash == image.image_orig_sha512_hash
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot clear the hash and it stays set" do
      # A nil actor fails the :hide authorization on the loaded image, so this is
      # a clean unauthorized rather than a crash.
      image = image_fixture()

      assert Images.remove_image_hash(nil, to_string(image.id)) == {:error, :unauthorized}
      assert Repo.reload!(image).image_orig_sha512_hash == image.image_orig_sha512_hash
      assert moderation_log_count() == 0
    end

    test "a successful clear writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} = Images.remove_image_hash(moderator, to_string(image.id))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Hash:delete"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Cleared hash of image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, cleared} = Images.remove_image_hash(moderator, image.id)
      assert cleared.id == image.id
    end

    test "a moderator with an unknown well-formed id is unauthorized" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found. No log.
      moderator = moderator_user_fixture()

      assert Images.remove_image_hash(moderator, "2147483647") == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.remove_image_hash(admin, "2147483647") == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.remove_image_hash(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, ahead of any authorization.
      moderator = moderator_user_fixture()

      assert Images.remove_image_hash(moderator, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "repair_image/2" do
    test "a moderator flags the image for reprocessing and gets the image" do
      # The engine writes with update_all, so the returned struct still carries
      # the pre-repair flags; the cleared flags show on reload.
      moderator = moderator_user_fixture()
      image = image_fixture(processed: true, thumbnails_generated: true)

      assert {:ok, repaired} = Images.repair_image(moderator, to_string(image.id))
      assert repaired.id == image.id

      reloaded = Repo.reload!(image)
      refute reloaded.processed
      refute reloaded.thumbnails_generated
    end

    test "an admin flags the image for reprocessing" do
      admin = admin_user_fixture()
      image = image_fixture(processed: true, thumbnails_generated: true)

      assert {:ok, repaired} = Images.repair_image(admin, to_string(image.id))
      assert repaired.id == image.id

      reloaded = Repo.reload!(image)
      refute reloaded.processed
      refute reloaded.thumbnails_generated
    end

    test "a regular user cannot repair and the flags stay set" do
      user = confirmed_user_fixture()
      image = image_fixture(processed: true, thumbnails_generated: true)

      assert Images.repair_image(user, to_string(image.id)) == {:error, :unauthorized}

      reloaded = Repo.reload!(image)
      assert reloaded.processed
      assert reloaded.thumbnails_generated
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot repair and the flags stay set" do
      # A nil actor fails the :hide authorization on the loaded image, so this is
      # a clean unauthorized rather than a crash.
      image = image_fixture(processed: true, thumbnails_generated: true)

      assert Images.repair_image(nil, to_string(image.id)) == {:error, :unauthorized}

      reloaded = Repo.reload!(image)
      assert reloaded.processed
      assert reloaded.thumbnails_generated
      assert moderation_log_count() == 0
    end

    test "a successful repair writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} = Images.repair_image(moderator, to_string(image.id))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Repair:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Repaired image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, repaired} = Images.repair_image(moderator, image.id)
      assert repaired.id == image.id
    end

    test "a moderator with an unknown well-formed id is unauthorized" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found. No log.
      moderator = moderator_user_fixture()

      assert Images.repair_image(moderator, "2147483647") == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.repair_image(admin, "2147483647") == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.repair_image(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, ahead of any authorization.
      moderator = moderator_user_fixture()

      assert Images.repair_image(moderator, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "remove_source_history/2" do
    test "a moderator clears the source history and source_url and gets the image" do
      moderator = moderator_user_fixture()
      image = image_fixture(source_url: "https://example.com/artwork")
      source_change_fixture(image)
      source_change_fixture(image)
      assert source_change_count(image) == 2

      assert {:ok, cleared} = Images.remove_source_history(moderator, to_string(image.id))
      assert cleared.id == image.id

      reloaded = Repo.reload!(image)
      assert reloaded.source_url == nil
      assert source_change_count(image) == 0
    end

    test "an admin clears the source history and source_url" do
      admin = admin_user_fixture()
      image = image_fixture(source_url: "https://example.com/artwork")
      source_change_fixture(image)

      assert {:ok, cleared} = Images.remove_source_history(admin, to_string(image.id))
      assert cleared.id == image.id

      reloaded = Repo.reload!(image)
      assert reloaded.source_url == nil
      assert source_change_count(image) == 0
    end

    test "a regular user cannot clear the history and it stays intact" do
      user = confirmed_user_fixture()
      image = image_fixture(source_url: "https://example.com/artwork")
      source_change_fixture(image)

      assert Images.remove_source_history(user, to_string(image.id)) == {:error, :unauthorized}

      reloaded = Repo.reload!(image)
      assert reloaded.source_url == "https://example.com/artwork"
      assert source_change_count(image) == 1
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot clear the history and it stays intact" do
      # A nil actor fails the :hide authorization on the loaded image, so this is
      # a clean unauthorized rather than a crash.
      image = image_fixture(source_url: "https://example.com/artwork")
      source_change_fixture(image)

      assert Images.remove_source_history(nil, to_string(image.id)) == {:error, :unauthorized}

      reloaded = Repo.reload!(image)
      assert reloaded.source_url == "https://example.com/artwork"
      assert source_change_count(image) == 1
      assert moderation_log_count() == 0
    end

    test "a successful clear writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} = Images.remove_source_history(moderator, to_string(image.id))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.SourceHistory:delete"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Deleted source history for image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, cleared} = Images.remove_source_history(moderator, image.id)
      assert cleared.id == image.id
    end

    test "a moderator with an unknown well-formed id is unauthorized" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found. No log.
      moderator = moderator_user_fixture()

      assert Images.remove_source_history(moderator, "2147483647") == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.remove_source_history(admin, "2147483647") == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.remove_source_history(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, ahead of any authorization.
      moderator = moderator_user_fixture()

      assert Images.remove_source_history(moderator, "99999999999999999999") ==
               {:error, :not_found}
    end
  end

  describe "image_fave_list/2" do
    test "an anonymous actor gets the faves without vote data on a visible image" do
      image = image_fixture()

      assert {:ok, {loaded, has_votes}} = Images.image_fave_list(nil, to_string(image.id))
      assert loaded.id == image.id
      refute has_votes

      # Faves are always preloaded; the tamper-only vote associations are not.
      assert Ecto.assoc_loaded?(loaded.faves)
      refute Ecto.assoc_loaded?(loaded.upvotes)
      refute Ecto.assoc_loaded?(loaded.downvotes)
      refute Ecto.assoc_loaded?(loaded.hides)
    end

    test "a regular user gets the faves without vote data on a visible image" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, {loaded, has_votes}} = Images.image_fave_list(user, to_string(image.id))
      assert loaded.id == image.id
      refute has_votes

      assert Ecto.assoc_loaded?(loaded.faves)
      refute Ecto.assoc_loaded?(loaded.upvotes)
      refute Ecto.assoc_loaded?(loaded.downvotes)
      refute Ecto.assoc_loaded?(loaded.hides)
    end

    test "faves are preloaded with their user for any actor" do
      faver = confirmed_user_fixture()
      image = image_fixture()
      fave!(image, faver)

      assert {:ok, {loaded, _has_votes}} = Images.image_fave_list(nil, to_string(image.id))

      [fave] = loaded.faves
      assert fave.user.id == faver.id
    end

    test "a moderator gets has_votes true with the vote associations preloaded" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, {loaded, has_votes}} = Images.image_fave_list(moderator, to_string(image.id))
      assert loaded.id == image.id
      assert has_votes

      assert Ecto.assoc_loaded?(loaded.faves)
      assert Ecto.assoc_loaded?(loaded.upvotes)
      assert Ecto.assoc_loaded?(loaded.downvotes)
      assert Ecto.assoc_loaded?(loaded.hides)
    end

    test "an admin gets has_votes true" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, {loaded, has_votes}} = Images.image_fave_list(admin, to_string(image.id))
      assert loaded.id == image.id
      assert has_votes
    end

    test "a moderator's vote associations carry their users" do
      moderator = moderator_user_fixture()
      upvoter = confirmed_user_fixture()
      downvoter = confirmed_user_fixture()
      hider = confirmed_user_fixture()
      image = image_fixture()

      vote!(image, upvoter, true)
      vote!(image, downvoter, false)
      hide!(image, hider)

      assert {:ok, {loaded, true}} = Images.image_fave_list(moderator, to_string(image.id))

      assert [%{user: %{id: up_id}}] = loaded.upvotes
      assert up_id == upvoter.id
      assert [%{user: %{id: down_id}}] = loaded.downvotes
      assert down_id == downvoter.id
      assert [%{user: %{id: hide_id}}] = loaded.hides
      assert hide_id == hider.id
    end

    test "a hidden image is unauthorized for a regular user" do
      user = confirmed_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert Images.image_fave_list(user, to_string(image.id)) == {:error, :unauthorized}
    end

    test "a hidden image is unauthorized for an anonymous actor" do
      image = image_fixture(hidden_from_users: true)

      assert Images.image_fave_list(nil, to_string(image.id)) == {:error, :unauthorized}
    end

    test "a hidden image is listable by a moderator with has_votes true" do
      moderator = moderator_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert {:ok, {loaded, true}} = Images.image_fave_list(moderator, to_string(image.id))
      assert loaded.id == image.id
    end

    test "accepts an integer id" do
      image = image_fixture()

      assert {:ok, {loaded, false}} = Images.image_fave_list(nil, image.id)
      assert loaded.id == image.id
    end

    test "an unknown well-formed id is unauthorized for an anonymous actor" do
      # The image loads as nil and a nil actor fails :index on the nil load, so
      # the missing image surfaces as unauthorized rather than not found.
      assert Images.image_fave_list(nil, "2147483647") == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a regular user" do
      assert Images.image_fave_list(confirmed_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator" do
      assert Images.image_fave_list(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :index on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      assert Images.image_fave_list(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.image_fave_list(nil, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, ahead of any authorization.
      assert Images.image_fave_list(nil, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "load_image_for_scratchpad/2" do
    test "a moderator loads a known image" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_scratchpad(moderator, to_string(image.id))
      assert loaded.id == image.id
    end

    test "an admin loads a known image" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_scratchpad(admin, to_string(image.id))
      assert loaded.id == image.id
    end

    test "a regular user cannot load the image" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.load_image_for_scratchpad(user, to_string(image.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor cannot load the image" do
      image = image_fixture()

      assert Images.load_image_for_scratchpad(nil, to_string(image.id)) ==
               {:error, :unauthorized}
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_scratchpad(moderator, image.id)
      assert loaded.id == image.id
    end

    test "a moderator with an unknown well-formed id is unauthorized" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      moderator = moderator_user_fixture()

      assert Images.load_image_for_scratchpad(moderator, "2147483647") ==
               {:error, :unauthorized}
    end

    test "an admin with an unknown well-formed id is not found" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.load_image_for_scratchpad(admin, "2147483647") == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.load_image_for_scratchpad(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.load_image_for_scratchpad(moderator, "99999999999999999999") ==
               {:error, :not_found}
    end
  end

  describe "update_scratchpad/3" do
    test "a moderator stores the scratchpad and gets the image" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, updated} =
               Images.update_scratchpad(moderator, to_string(image.id), %{
                 "scratchpad" => "watch closely"
               })

      assert updated.id == image.id
      assert updated.scratchpad == "watch closely"
      assert Repo.reload!(image).scratchpad == "watch closely"
    end

    test "an admin stores the scratchpad" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, _updated} =
               Images.update_scratchpad(admin, to_string(image.id), %{"scratchpad" => "noted"})

      assert Repo.reload!(image).scratchpad == "noted"
    end

    test "a blank scratchpad clears the field to nil" do
      moderator = moderator_user_fixture()
      image = image_fixture(scratchpad: "existing note")

      assert {:ok, updated} =
               Images.update_scratchpad(moderator, to_string(image.id), %{"scratchpad" => ""})

      assert updated.scratchpad == nil
      assert Repo.reload!(image).scratchpad == nil
    end

    test "a successful update writes an exact moderation log with the new value" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.update_scratchpad(moderator, to_string(image.id), %{
                 "scratchpad" => "watch closely"
               })

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Scratchpad:update"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Updated mod notes on image #{image.id} (watch closely)"
    end

    test "clearing the scratchpad logs an empty value in the parentheses" do
      moderator = moderator_user_fixture()
      image = image_fixture(scratchpad: "existing note")

      assert {:ok, _} =
               Images.update_scratchpad(moderator, to_string(image.id), %{"scratchpad" => ""})

      log = only_moderation_log!()
      assert log.body == "Updated mod notes on image #{image.id} ()"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, updated} =
               Images.update_scratchpad(moderator, image.id, %{"scratchpad" => "noted"})

      assert updated.scratchpad == "noted"
    end

    test "a regular user cannot update and the scratchpad and log stay untouched" do
      user = confirmed_user_fixture()
      image = image_fixture(scratchpad: "existing note")

      assert Images.update_scratchpad(user, to_string(image.id), %{"scratchpad" => "new"}) ==
               {:error, :unauthorized}

      assert Repo.reload!(image).scratchpad == "existing note"
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot update and the scratchpad and log stay untouched" do
      image = image_fixture(scratchpad: "existing note")

      assert Images.update_scratchpad(nil, to_string(image.id), %{"scratchpad" => "new"}) ==
               {:error, :unauthorized}

      assert Repo.reload!(image).scratchpad == "existing note"
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      moderator = moderator_user_fixture()

      assert Images.update_scratchpad(moderator, "2147483647", %{"scratchpad" => "new"}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      admin = admin_user_fixture()

      assert Images.update_scratchpad(admin, "2147483647", %{"scratchpad" => "new"}) ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_scratchpad(moderator, "not-a-number", %{"scratchpad" => "new"}) ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_scratchpad(moderator, "99999999999999999999", %{"scratchpad" => "new"}) ==
               {:error, :not_found}
    end
  end

  describe "subscribe_image/2" do
    test "a regular user subscribes to a visible image and the row is created" do
      # The :show authorization admits a regular user on a visible image, so
      # subscribing is not staff-gated.
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, subscribed} = Images.subscribe_image(user, to_string(image.id))
      assert subscribed.id == image.id
      assert Images.subscribed?(image, user)
    end

    test "a moderator subscribes to a visible image" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} = Images.subscribe_image(moderator, to_string(image.id))
      assert Images.subscribed?(image, moderator)
    end

    test "subscribing twice is idempotent and stays subscribed" do
      # create_subscription inserts with on_conflict: :nothing, so a repeat is a
      # successful no-op rather than a changeset error.
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, _} = Images.subscribe_image(user, to_string(image.id))
      assert {:ok, _} = Images.subscribe_image(user, to_string(image.id))
      assert Images.subscribed?(image, user)
    end

    test "a banned user still subscribes" do
      # subscribe_image runs no ban check, so a banned actor reaches the
      # subscription just like any other viewer.
      user = banned_user_fixture()
      image = image_fixture()

      assert {:ok, _} = Images.subscribe_image(user, to_string(image.id))
      assert Images.subscribed?(image, user)
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, subscribed} = Images.subscribe_image(user, image.id)
      assert subscribed.id == image.id
    end

    test "an unknown well-formed id is unauthorized for an anonymous actor" do
      # The image loads as nil and a nil actor fails :show on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      assert Images.subscribe_image(nil, "2147483647") == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a regular user" do
      assert Images.subscribe_image(confirmed_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator" do
      assert Images.subscribe_image(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :show on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      assert Images.subscribe_image(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.subscribe_image(confirmed_user_fixture(), "not-a-number") ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, ahead of any authorization.
      assert Images.subscribe_image(confirmed_user_fixture(), "99999999999999999999") ==
               {:error, :not_found}
    end
  end

  describe "unsubscribe_image/2" do
    test "a regular user unsubscribes from a visible image and the row is removed" do
      user = confirmed_user_fixture()
      image = image_fixture()
      {:ok, _} = Images.create_subscription(image, user)
      assert Images.subscribed?(image, user)

      assert {:ok, unsubscribed} = Images.unsubscribe_image(user, to_string(image.id))
      assert unsubscribed.id == image.id
      refute Images.subscribed?(image, user)
    end

    test "unsubscribing with no existing subscription still succeeds" do
      # delete_subscription runs an unconditional delete and hard-matches {:ok, _},
      # so the absence of a row is not an error.
      user = confirmed_user_fixture()
      image = image_fixture()
      refute Images.subscribed?(image, user)

      assert {:ok, unsubscribed} = Images.unsubscribe_image(user, to_string(image.id))
      assert unsubscribed.id == image.id
      refute Images.subscribed?(image, user)
    end

    test "a banned user still unsubscribes" do
      user = banned_user_fixture()
      image = image_fixture()
      {:ok, _} = Images.create_subscription(image, user)

      assert {:ok, _} = Images.unsubscribe_image(user, to_string(image.id))
      refute Images.subscribed?(image, user)
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()
      {:ok, _} = Images.create_subscription(image, user)

      assert {:ok, unsubscribed} = Images.unsubscribe_image(user, image.id)
      assert unsubscribed.id == image.id
      refute Images.subscribed?(image, user)
    end

    test "an unknown well-formed id is unauthorized for an anonymous actor" do
      assert Images.unsubscribe_image(nil, "2147483647") == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a regular user" do
      assert Images.unsubscribe_image(confirmed_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator" do
      assert Images.unsubscribe_image(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      assert Images.unsubscribe_image(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.unsubscribe_image(confirmed_user_fixture(), "not-a-number") ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert Images.unsubscribe_image(confirmed_user_fixture(), "99999999999999999999") ==
               {:error, :not_found}
    end
  end

  describe "approve_image/2" do
    test "a moderator approves an unapproved image and gets the image" do
      moderator = moderator_user_fixture()
      image = image_fixture(approved: false)

      assert {:ok, approved} = Images.approve_image(moderator, to_string(image.id))
      assert approved.id == image.id
      assert approved.approved
      assert Repo.reload!(image).approved
    end

    test "an admin approves an unapproved image" do
      admin = admin_user_fixture()
      image = image_fixture(approved: false)

      assert {:ok, _} = Images.approve_image(admin, to_string(image.id))
      assert Repo.reload!(image).approved
    end

    test "approving increments the uploader's image count" do
      moderator = moderator_user_fixture()
      uploader = confirmed_user_fixture()
      image = image_fixture(approved: false, user_id: uploader.id)
      assert Repo.reload!(uploader).images_count == 0

      assert {:ok, _} = Images.approve_image(moderator, to_string(image.id))
      assert Repo.reload!(uploader).images_count == 1
    end

    test "a successful approval writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(approved: false)

      assert {:ok, _} = Images.approve_image(moderator, to_string(image.id))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Approve:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Approved image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture(approved: false)

      assert {:ok, approved} = Images.approve_image(moderator, image.id)
      assert approved.id == image.id
    end

    test "an already-approved image is already_approved with no log or state change" do
      moderator = moderator_user_fixture()
      image = image_fixture(approved: true)

      assert Images.approve_image(moderator, to_string(image.id)) ==
               {:error, :already_approved}

      assert Repo.reload!(image).approved
      assert moderation_log_count() == 0
    end

    test "a regular user on an already-approved image is unauthorized, not already_approved" do
      # Authorization runs before the approved-state check, so a regular user
      # fails :approve and never reaches the already_approved branch.
      user = confirmed_user_fixture()
      image = image_fixture(approved: true)

      assert Images.approve_image(user, to_string(image.id)) == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "a regular user cannot approve an unapproved image and it stays unapproved" do
      user = confirmed_user_fixture()
      image = image_fixture(approved: false)

      assert Images.approve_image(user, to_string(image.id)) == {:error, :unauthorized}
      refute Repo.reload!(image).approved
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot approve an unapproved image" do
      image = image_fixture(approved: false)

      assert Images.approve_image(nil, to_string(image.id)) == {:error, :unauthorized}
      refute Repo.reload!(image).approved
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized" do
      # The image loads as nil and a moderator fails :approve on the nil load, so
      # the missing image surfaces as unauthorized rather than not found. No log.
      moderator = moderator_user_fixture()

      assert Images.approve_image(moderator, "2147483647") == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found" do
      # An admin clears :approve on the nil load via the blanket ability rule,
      # then the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.approve_image(admin, "2147483647") == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.approve_image(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.approve_image(moderator, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "set_comment_locked/3" do
    test "a moderator locks comments, clearing commenting_allowed" do
      moderator = moderator_user_fixture()
      image = image_fixture(commenting_allowed: true)

      assert {:ok, locked} = Images.set_comment_locked(moderator, to_string(image.id), true)
      assert locked.id == image.id
      refute locked.commenting_allowed
      refute Repo.reload!(image).commenting_allowed
    end

    test "an admin locks comments" do
      admin = admin_user_fixture()
      image = image_fixture(commenting_allowed: true)

      assert {:ok, _} = Images.set_comment_locked(admin, to_string(image.id), true)
      refute Repo.reload!(image).commenting_allowed
    end

    test "a moderator unlocks comments, setting commenting_allowed" do
      moderator = moderator_user_fixture()
      image = image_fixture(commenting_allowed: false)

      assert {:ok, unlocked} = Images.set_comment_locked(moderator, to_string(image.id), false)
      assert unlocked.id == image.id
      assert unlocked.commenting_allowed
      assert Repo.reload!(image).commenting_allowed
    end

    test "locking writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(commenting_allowed: true)

      assert {:ok, _} = Images.set_comment_locked(moderator, to_string(image.id), true)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.CommentLock:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Locked comments on image #{image.id}"
    end

    test "unlocking writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(commenting_allowed: false)

      assert {:ok, _} = Images.set_comment_locked(moderator, to_string(image.id), false)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.CommentLock:delete"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Unlocked comments on image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture(commenting_allowed: true)

      assert {:ok, locked} = Images.set_comment_locked(moderator, image.id, true)
      assert locked.id == image.id
    end

    test "a regular user cannot lock comments and the flag stays set" do
      user = confirmed_user_fixture()
      image = image_fixture(commenting_allowed: true)

      assert Images.set_comment_locked(user, to_string(image.id), true) ==
               {:error, :unauthorized}

      assert Repo.reload!(image).commenting_allowed
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot lock comments and the flag stays set" do
      image = image_fixture(commenting_allowed: true)

      assert Images.set_comment_locked(nil, to_string(image.id), true) ==
               {:error, :unauthorized}

      assert Repo.reload!(image).commenting_allowed
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      moderator = moderator_user_fixture()

      assert Images.set_comment_locked(moderator, "2147483647", true) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.set_comment_locked(admin, "2147483647", true) == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.set_comment_locked(moderator, "not-a-number", true) == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.set_comment_locked(moderator, "99999999999999999999", true) ==
               {:error, :not_found}
    end
  end

  describe "set_description_locked/3" do
    test "a moderator locks description editing, clearing description_editing_allowed" do
      moderator = moderator_user_fixture()
      image = image_fixture(description_editing_allowed: true)

      assert {:ok, locked} = Images.set_description_locked(moderator, to_string(image.id), true)
      assert locked.id == image.id
      refute locked.description_editing_allowed
      refute Repo.reload!(image).description_editing_allowed
    end

    test "an admin locks description editing" do
      admin = admin_user_fixture()
      image = image_fixture(description_editing_allowed: true)

      assert {:ok, _} = Images.set_description_locked(admin, to_string(image.id), true)
      refute Repo.reload!(image).description_editing_allowed
    end

    test "a moderator unlocks description editing, setting description_editing_allowed" do
      moderator = moderator_user_fixture()
      image = image_fixture(description_editing_allowed: false)

      assert {:ok, unlocked} =
               Images.set_description_locked(moderator, to_string(image.id), false)

      assert unlocked.id == image.id
      assert unlocked.description_editing_allowed
      assert Repo.reload!(image).description_editing_allowed
    end

    test "locking writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(description_editing_allowed: true)

      assert {:ok, _} = Images.set_description_locked(moderator, to_string(image.id), true)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.DescriptionLock:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Locked description editing on image #{image.id}"
    end

    test "unlocking writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(description_editing_allowed: false)

      assert {:ok, _} = Images.set_description_locked(moderator, to_string(image.id), false)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.DescriptionLock:delete"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Unlocked description editing on image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture(description_editing_allowed: true)

      assert {:ok, locked} = Images.set_description_locked(moderator, image.id, true)
      assert locked.id == image.id
    end

    test "a regular user cannot lock description editing and the flag stays set" do
      user = confirmed_user_fixture()
      image = image_fixture(description_editing_allowed: true)

      assert Images.set_description_locked(user, to_string(image.id), true) ==
               {:error, :unauthorized}

      assert Repo.reload!(image).description_editing_allowed
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot lock description editing and the flag stays set" do
      image = image_fixture(description_editing_allowed: true)

      assert Images.set_description_locked(nil, to_string(image.id), true) ==
               {:error, :unauthorized}

      assert Repo.reload!(image).description_editing_allowed
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      moderator = moderator_user_fixture()

      assert Images.set_description_locked(moderator, "2147483647", true) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.set_description_locked(admin, "2147483647", true) == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.set_description_locked(moderator, "not-a-number", true) ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.set_description_locked(moderator, "99999999999999999999", true) ==
               {:error, :not_found}
    end
  end

  describe "set_tag_locked/3" do
    test "a moderator locks tags, clearing tag_editing_allowed" do
      moderator = moderator_user_fixture()
      image = image_fixture(tag_editing_allowed: true)

      assert {:ok, locked} = Images.set_tag_locked(moderator, to_string(image.id), true)
      assert locked.id == image.id
      refute locked.tag_editing_allowed
      refute Repo.reload!(image).tag_editing_allowed
    end

    test "an admin locks tags" do
      admin = admin_user_fixture()
      image = image_fixture(tag_editing_allowed: true)

      assert {:ok, _} = Images.set_tag_locked(admin, to_string(image.id), true)
      refute Repo.reload!(image).tag_editing_allowed
    end

    test "a moderator unlocks tags, setting tag_editing_allowed" do
      moderator = moderator_user_fixture()
      image = image_fixture(tag_editing_allowed: false)

      assert {:ok, unlocked} = Images.set_tag_locked(moderator, to_string(image.id), false)
      assert unlocked.id == image.id
      assert unlocked.tag_editing_allowed
      assert Repo.reload!(image).tag_editing_allowed
    end

    test "locking writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(tag_editing_allowed: true)

      assert {:ok, _} = Images.set_tag_locked(moderator, to_string(image.id), true)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.TagLock:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Locked tags on image #{image.id}"
    end

    test "unlocking writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(tag_editing_allowed: false)

      assert {:ok, _} = Images.set_tag_locked(moderator, to_string(image.id), false)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.TagLock:delete"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Unlocked tags on image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture(tag_editing_allowed: true)

      assert {:ok, locked} = Images.set_tag_locked(moderator, image.id, true)
      assert locked.id == image.id
    end

    test "a regular user cannot lock tags and the flag stays set" do
      user = confirmed_user_fixture()
      image = image_fixture(tag_editing_allowed: true)

      assert Images.set_tag_locked(user, to_string(image.id), true) == {:error, :unauthorized}
      assert Repo.reload!(image).tag_editing_allowed
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot lock tags and the flag stays set" do
      image = image_fixture(tag_editing_allowed: true)

      assert Images.set_tag_locked(nil, to_string(image.id), true) == {:error, :unauthorized}
      assert Repo.reload!(image).tag_editing_allowed
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      moderator = moderator_user_fixture()

      assert Images.set_tag_locked(moderator, "2147483647", true) == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.set_tag_locked(admin, "2147483647", true) == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.set_tag_locked(moderator, "not-a-number", true) == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.set_tag_locked(moderator, "99999999999999999999", true) ==
               {:error, :not_found}
    end
  end

  describe "load_image_for_tag_lock/2" do
    test "a moderator loads a known image with its locked tags preloaded" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_tag_lock(moderator, to_string(image.id))
      assert loaded.id == image.id
      assert Ecto.assoc_loaded?(loaded.locked_tags)
    end

    test "an admin loads a known image with its locked tags preloaded" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_tag_lock(admin, to_string(image.id))
      assert loaded.id == image.id
      assert Ecto.assoc_loaded?(loaded.locked_tags)
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_tag_lock(moderator, image.id)
      assert loaded.id == image.id
    end

    test "a regular user cannot load the image" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.load_image_for_tag_lock(user, to_string(image.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor cannot load the image" do
      image = image_fixture()

      assert Images.load_image_for_tag_lock(nil, to_string(image.id)) == {:error, :unauthorized}
    end

    test "a moderator with an unknown well-formed id is unauthorized" do
      moderator = moderator_user_fixture()

      assert Images.load_image_for_tag_lock(moderator, "2147483647") == {:error, :unauthorized}
    end

    test "an admin with an unknown well-formed id is not found" do
      admin = admin_user_fixture()

      assert Images.load_image_for_tag_lock(admin, "2147483647") == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.load_image_for_tag_lock(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.load_image_for_tag_lock(moderator, "99999999999999999999") ==
               {:error, :not_found}
    end
  end

  describe "update_locked_tags/3" do
    test "a moderator replaces the locked-tags list" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      # Seed a starting locked tag, then replace it wholesale.
      {:ok, _} = Images.update_locked_tags(image, %{"tag_input" => "old lock"})
      assert locked_tag_names(image) == ["old lock"]

      assert {:ok, updated} =
               Images.update_locked_tags(moderator, to_string(image.id), %{
                 "tag_input" => "safe, cute"
               })

      assert updated.id == image.id
      assert locked_tag_names(image) == ["cute", "safe"]
    end

    test "an empty tag_input clears the locked-tags list" do
      moderator = moderator_user_fixture()
      image = image_fixture()
      {:ok, _} = Images.update_locked_tags(image, %{"tag_input" => "safe, cute"})
      assert locked_tag_names(image) == ["cute", "safe"]

      assert {:ok, _} =
               Images.update_locked_tags(moderator, to_string(image.id), %{"tag_input" => ""})

      assert locked_tag_names(image) == []
    end

    test "an admin replaces the locked-tags list" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.update_locked_tags(admin, to_string(image.id), %{"tag_input" => "safe"})

      assert locked_tag_names(image) == ["safe"]
    end

    test "a successful update writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.update_locked_tags(moderator, to_string(image.id), %{
                 "tag_input" => "safe, cute"
               })

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.TagLock:update"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Updated list of locked tags on image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, updated} =
               Images.update_locked_tags(moderator, image.id, %{"tag_input" => "safe"})

      assert updated.id == image.id
      assert locked_tag_names(image) == ["safe"]
    end

    test "a regular user cannot update and the list and log stay untouched" do
      user = confirmed_user_fixture()
      image = image_fixture()
      {:ok, _} = Images.update_locked_tags(image, %{"tag_input" => "safe"})

      assert Images.update_locked_tags(user, to_string(image.id), %{"tag_input" => "cute"}) ==
               {:error, :unauthorized}

      assert locked_tag_names(image) == ["safe"]
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot update and the list and log stay untouched" do
      image = image_fixture()
      {:ok, _} = Images.update_locked_tags(image, %{"tag_input" => "safe"})

      assert Images.update_locked_tags(nil, to_string(image.id), %{"tag_input" => "cute"}) ==
               {:error, :unauthorized}

      assert locked_tag_names(image) == ["safe"]
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      moderator = moderator_user_fixture()

      assert Images.update_locked_tags(moderator, "2147483647", %{"tag_input" => "safe"}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      admin = admin_user_fixture()

      assert Images.update_locked_tags(admin, "2147483647", %{"tag_input" => "safe"}) ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_locked_tags(moderator, "not-a-number", %{"tag_input" => "safe"}) ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_locked_tags(moderator, "99999999999999999999", %{"tag_input" => "safe"}) ==
               {:error, :not_found}
    end
  end

  describe "feature_image/2" do
    test "a moderator features a visible image, creating the feature row" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, %ImageFeature{} = feature} =
               Images.feature_image(moderator, to_string(image.id))

      assert feature.image_id == image.id
      assert feature.user_id == moderator.id
      assert feature_row_count(image) == 1
    end

    test "an admin features a visible image" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, %ImageFeature{}} = Images.feature_image(admin, to_string(image.id))
      assert feature_row_count(image) == 1
    end

    test "a successful feature writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} = Images.feature_image(moderator, to_string(image.id))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Feature:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Featured image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, %ImageFeature{}} = Images.feature_image(moderator, image.id)
      assert feature_row_count(image) == 1
    end

    test "a hidden image is deleted with no feature row and no log" do
      moderator = moderator_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert Images.feature_image(moderator, to_string(image.id)) == {:error, :deleted}
      assert feature_row_count(image) == 0
      assert moderation_log_count() == 0
    end

    test "a regular user on a hidden image is unauthorized, not deleted" do
      # Authorization runs before the hidden-state check, so a regular user fails
      # :hide and never reaches the deleted branch.
      user = confirmed_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert Images.feature_image(user, to_string(image.id)) == {:error, :unauthorized}
      assert feature_row_count(image) == 0
      assert moderation_log_count() == 0
    end

    test "a regular user cannot feature a visible image" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.feature_image(user, to_string(image.id)) == {:error, :unauthorized}
      assert feature_row_count(image) == 0
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot feature a visible image" do
      image = image_fixture()

      assert Images.feature_image(nil, to_string(image.id)) == {:error, :unauthorized}
      assert feature_row_count(image) == 0
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      moderator = moderator_user_fixture()

      assert Images.feature_image(moderator, "2147483647") == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.feature_image(admin, "2147483647") == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.feature_image(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.feature_image(moderator, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "update_file/3" do
    test "a moderator replaces the file and gets the image" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, updated} =
               Images.update_file(moderator, to_string(image.id), %{"image" => png_upload()})

      assert updated.id == image.id
      assert Repo.reload!(image).image_sha512_hash == png_upload_sha512()
    end

    test "an admin replaces the file" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.update_file(admin, to_string(image.id), %{"image" => png_upload()})

      assert Repo.reload!(image).image_sha512_hash == png_upload_sha512()
    end

    test "a successful replacement writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.update_file(moderator, to_string(image.id), %{"image" => png_upload()})

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.File:update"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Updated file of image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, updated} =
               Images.update_file(moderator, image.id, %{"image" => png_upload()})

      assert updated.id == image.id
    end

    test "a file duplicating another image is a changeset error with no log" do
      moderator = moderator_user_fixture()
      dup_sha = png_upload_sha512()
      _other = image_fixture(image_sha512_hash: dup_sha, image_orig_sha512_hash: dup_sha)
      image = image_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Images.update_file(moderator, to_string(image.id), %{"image" => png_upload()})

      assert moderation_log_count() == 0
    end

    test "a missing file is a changeset error with no log" do
      # With no "image" key the upload analysis fails the required-file check, so
      # the engine returns the changeset error the wrapper passes straight
      # through without logging.
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Images.update_file(moderator, to_string(image.id), %{})

      assert moderation_log_count() == 0
    end

    test "a hidden image is deleted with no log" do
      moderator = moderator_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert Images.update_file(moderator, to_string(image.id), %{"image" => png_upload()}) ==
               {:error, :deleted}

      assert moderation_log_count() == 0
    end

    test "a regular user on a hidden image is unauthorized, not deleted" do
      # Authorization runs before the hidden-state check, so a regular user fails
      # :hide and never reaches the deleted branch.
      user = confirmed_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert Images.update_file(user, to_string(image.id), %{"image" => png_upload()}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "a regular user cannot replace the file" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.update_file(user, to_string(image.id), %{"image" => png_upload()}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot replace the file" do
      image = image_fixture()

      assert Images.update_file(nil, to_string(image.id), %{"image" => png_upload()}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      # The image loads as nil and a moderator fails :hide on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      moderator = moderator_user_fixture()

      assert Images.update_file(moderator, "2147483647", %{"image" => png_upload()}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      # An admin clears :hide on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.update_file(admin, "2147483647", %{"image" => png_upload()}) ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_file(moderator, "not-a-number", %{"image" => png_upload()}) ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_file(moderator, "99999999999999999999", %{"image" => png_upload()}) ==
               {:error, :not_found}
    end
  end

  describe "update_anonymous/3" do
    test "a moderator sets anonymity, flagging the image anonymous" do
      moderator = moderator_user_fixture()
      image = image_fixture(anonymous: false)

      assert {:ok, updated} = Images.update_anonymous(moderator, to_string(image.id), true)
      assert updated.id == image.id
      assert updated.anonymous
      assert Repo.reload!(image).anonymous
    end

    test "an admin sets anonymity" do
      admin = admin_user_fixture()
      image = image_fixture(anonymous: false)

      assert {:ok, _} = Images.update_anonymous(admin, to_string(image.id), true)
      assert Repo.reload!(image).anonymous
    end

    test "a moderator clears anonymity" do
      moderator = moderator_user_fixture()
      image = image_fixture(anonymous: true)

      assert {:ok, updated} = Images.update_anonymous(moderator, to_string(image.id), false)
      assert updated.id == image.id
      refute updated.anonymous
      refute Repo.reload!(image).anonymous
    end

    test "setting anonymity writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(anonymous: false)

      assert {:ok, _} = Images.update_anonymous(moderator, to_string(image.id), true)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Anonymous:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Updated anonymity of image #{image.id}"
    end

    test "clearing anonymity writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture(anonymous: true)

      assert {:ok, _} = Images.update_anonymous(moderator, to_string(image.id), false)

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Anonymous:delete"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Updated anonymity of image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture(anonymous: false)

      assert {:ok, updated} = Images.update_anonymous(moderator, image.id, true)
      assert updated.id == image.id
      assert Repo.reload!(image).anonymous
    end

    test "a regular user is unauthorized on a real image and the flag stays put" do
      # Authorization on :ip_address runs before the load, so a regular user is
      # denied without the image ever being touched.
      user = confirmed_user_fixture()
      image = image_fixture(anonymous: false)

      assert Images.update_anonymous(user, to_string(image.id), true) == {:error, :unauthorized}
      refute Repo.reload!(image).anonymous
      assert moderation_log_count() == 0
    end

    test "a regular user with a garbage id is still unauthorized, not not_found" do
      # The :ip_address authorization precedes the id parse, so a non-castable id
      # never reaches the not-found path for an unprivileged actor.
      user = confirmed_user_fixture()

      assert Images.update_anonymous(user, "not-a-number", true) == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an anonymous actor is unauthorized on a real image" do
      image = image_fixture(anonymous: false)

      assert Images.update_anonymous(nil, to_string(image.id), true) == {:error, :unauthorized}
      refute Repo.reload!(image).anonymous
      assert moderation_log_count() == 0
    end

    test "an anonymous actor with a garbage id is still unauthorized" do
      assert Images.update_anonymous(nil, "not-a-number", true) == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is not found and writes no log" do
      # Unlike the :hide wrappers, the load has no per-image authorization, so a
      # missing image is a plain not-found rather than unauthorized.
      moderator = moderator_user_fixture()

      assert Images.update_anonymous(moderator, "2147483647", true) == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a moderator with a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_anonymous(moderator, "not-a-number", true) == {:error, :not_found}
    end

    test "a moderator with an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_anonymous(moderator, "99999999999999999999", true) ==
               {:error, :not_found}
    end
  end

  describe "destroy_image/2" do
    test "an Image-admin role_map moderator destroys a hidden image, nulling the file" do
      moderator = role_moderator_fixture("Image")
      image = image_fixture(hidden_from_users: true)

      assert {:ok, destroyed} = Images.destroy_image(moderator, to_string(image.id))
      assert destroyed.id == image.id
      assert Repo.reload!(image).image == nil
    end

    test "an admin destroys a hidden image" do
      admin = admin_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert {:ok, _} = Images.destroy_image(admin, to_string(image.id))
      assert Repo.reload!(image).image == nil
    end

    test "a successful destroy writes an exact moderation log" do
      admin = admin_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert {:ok, _} = Images.destroy_image(admin, to_string(image.id))

      log = only_moderation_log!()
      assert log.user_id == admin.id
      assert log.type == "Image.Destroy:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Hard-deleted image #{image.id}"
    end

    test "accepts an integer id" do
      admin = admin_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert {:ok, destroyed} = Images.destroy_image(admin, image.id)
      assert destroyed.id == image.id
      assert Repo.reload!(image).image == nil
    end

    test "a visible image is not_deleted with the file intact and no log" do
      # The precondition requires a hidden image; a still-visible one is refused
      # before any change.
      admin = admin_user_fixture()
      image = image_fixture(hidden_from_users: false)

      assert Images.destroy_image(admin, to_string(image.id)) == {:error, :not_deleted}
      assert Repo.reload!(image).image == image.image
      assert moderation_log_count() == 0
    end

    test "a plain moderator cannot destroy a hidden image and the file stays intact" do
      # :destroy needs an Image-admin role_map grant, which a plain moderator
      # lacks, so this is unauthorized even though the image is hidden.
      moderator = moderator_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert Images.destroy_image(moderator, to_string(image.id)) == {:error, :unauthorized}
      assert Repo.reload!(image).image == image.image
      assert moderation_log_count() == 0
    end

    test "a plain moderator on a visible image is unauthorized, not not_deleted" do
      # Authorization runs before the hidden-state check, so a plain moderator
      # fails :destroy and never reaches the not_deleted branch.
      moderator = moderator_user_fixture()
      image = image_fixture(hidden_from_users: false)

      assert Images.destroy_image(moderator, to_string(image.id)) == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "a regular user cannot destroy a hidden image" do
      user = confirmed_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert Images.destroy_image(user, to_string(image.id)) == {:error, :unauthorized}
      assert Repo.reload!(image).image == image.image
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot destroy a hidden image" do
      image = image_fixture(hidden_from_users: true)

      assert Images.destroy_image(nil, to_string(image.id)) == {:error, :unauthorized}
      assert Repo.reload!(image).image == image.image
      assert moderation_log_count() == 0
    end

    test "an Image-admin role_map moderator with an unknown well-formed id is unauthorized" do
      # The image loads as nil and the :destroy grant does not extend to the nil
      # load, so the missing image surfaces as unauthorized. No log.
      moderator = role_moderator_fixture("Image")

      assert Images.destroy_image(moderator, "2147483647") == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found" do
      # An admin clears :destroy on the nil load via the blanket ability rule,
      # then the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()

      assert Images.destroy_image(admin, "2147483647") == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      admin = admin_user_fixture()

      assert Images.destroy_image(admin, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      admin = admin_user_fixture()

      assert Images.destroy_image(admin, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "update_description/3" do
    test "the uploader edits its own image, persisting the new description" do
      uploader = confirmed_user_fixture()
      image = image_fixture(user_id: uploader.id)

      assert {:ok, {updated, old_description}} =
               Images.update_description(actor(uploader), to_string(image.id), %{
                 "description" => "A fresh description"
               })

      assert updated.id == image.id
      assert updated.description == "A fresh description"
      assert Repo.reload!(image).description == "A fresh description"
      # NOTE: a never-described image carries the column default "", so the
      # returned prior value is the empty string, not nil.
      assert old_description == ""
      assert moderation_log_count() == 0
    end

    test "old_description carries the exact pre-update value" do
      uploader = confirmed_user_fixture()
      image = image_fixture(user_id: uploader.id, description: "Original text")

      assert {:ok, {_updated, old_description}} =
               Images.update_description(actor(uploader), to_string(image.id), %{
                 "description" => "Replacement text"
               })

      assert old_description == "Original text"
      assert Repo.reload!(image).description == "Replacement text"
    end

    test "a moderator edits another user's image" do
      moderator = moderator_user_fixture()
      uploader = confirmed_user_fixture()
      image = image_fixture(user_id: uploader.id)

      assert {:ok, {updated, _old}} =
               Images.update_description(actor(moderator), to_string(image.id), %{
                 "description" => "Moderator edit"
               })

      assert updated.description == "Moderator edit"
      assert Repo.reload!(image).description == "Moderator edit"
    end

    test "accepts an integer id" do
      uploader = confirmed_user_fixture()
      image = image_fixture(user_id: uploader.id)

      assert {:ok, {updated, _old}} =
               Images.update_description(actor(uploader), image.id, %{"description" => "Via int"})

      assert updated.description == "Via int"
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      # verify_write_access runs first, so a banned actor is {:error, :ban} even
      # against an id that could never parse.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Images.update_description(actor, "not-a-number", %{"description" => "x"}) ==
               {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Images.update_description(actor, "not-a-number", %{"description" => "x"}) ==
               {:error, :unauthorized}
    end

    test "the uploader cannot edit when description editing is locked" do
      uploader = confirmed_user_fixture()
      image = image_fixture(user_id: uploader.id, description_editing_allowed: false)

      assert Images.update_description(actor(uploader), to_string(image.id), %{
               "description" => "blocked"
             }) == {:error, :unauthorized}

      assert Repo.reload!(image).description == image.description
    end

    test "a non-uploader regular user cannot edit the image" do
      owner = confirmed_user_fixture()
      other = confirmed_user_fixture()
      image = image_fixture(user_id: owner.id)

      assert Images.update_description(actor(other), to_string(image.id), %{
               "description" => "not mine"
             }) == {:error, :unauthorized}

      assert Repo.reload!(image).description == image.description
    end

    test "an anonymous actor with a fingerprint cannot edit the image" do
      # verify_write_access passes (fingerprint present, no ban) but the nil user
      # fails :edit_description, so this is unauthorized rather than a write.
      owner = confirmed_user_fixture()
      image = image_fixture(user_id: owner.id)

      assert Images.update_description(actor(nil), to_string(image.id), %{
               "description" => "anon"
             }) == {:error, :unauthorized}

      assert Repo.reload!(image).description == image.description
    end

    test "an over-long description is a changeset error with the image unchanged" do
      uploader = confirmed_user_fixture()
      image = image_fixture(user_id: uploader.id, description: "Original")
      too_long = String.duplicate("a", 50_001)

      assert {:error, %Ecto.Changeset{}} =
               Images.update_description(actor(uploader), to_string(image.id), %{
                 "description" => too_long
               })

      assert Repo.reload!(image).description == "Original"
    end

    test "an unknown well-formed id is unauthorized for a non-admin actor" do
      # The image loads as nil and a regular user fails :edit_description on the
      # nil load, so the missing image surfaces as unauthorized.
      assert Images.update_description(actor(confirmed_user_fixture()), "2147483647", %{
               "description" => "x"
             }) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :edit_description on the nil load via the blanket ability
      # rule, then the image presence check fails, so the missing image is not
      # found.
      assert Images.update_description(actor(admin_user_fixture()), "2147483647", %{
               "description" => "x"
             }) == {:error, :not_found}
    end

    test "a non-castable id is not found for a valid actor" do
      assert Images.update_description(actor(confirmed_user_fixture()), "not-a-number", %{
               "description" => "x"
             }) == {:error, :not_found}
    end

    test "an out-of-range id is not found for a valid actor" do
      assert Images.update_description(actor(confirmed_user_fixture()), "99999999999999999999", %{
               "description" => "x"
             }) == {:error, :not_found}
    end
  end

  describe "delete_user_vote/3" do
    test "a moderator removes a target user's upvote, adjusting the score" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()
      image = image_fixture()
      baseline_score = Repo.reload!(image).score

      vote!(image, target, true)
      assert has_vote?(image, target)
      assert Repo.reload!(image).score == baseline_score + 1

      assert {:ok, returned} =
               Images.delete_user_vote(moderator, to_string(image.id), to_string(target.id))

      assert returned.id == image.id
      refute has_vote?(image, target)
      assert Repo.reload!(image).score == baseline_score
    end

    test "removing an upvote writes an exact moderation log" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()
      image = image_fixture()
      vote!(image, target, true)

      assert {:ok, _} =
               Images.delete_user_vote(moderator, to_string(image.id), to_string(target.id))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Tamper:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Deleted upvote by #{target.name} on image #{image.id}"
    end

    test "removing a downvote writes a log naming a downvote" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()
      image = image_fixture()
      vote!(image, target, false)

      assert {:ok, _} =
               Images.delete_user_vote(moderator, to_string(image.id), to_string(target.id))

      refute has_vote?(image, target)

      log = only_moderation_log!()
      assert log.body == "Deleted downvote by #{target.name} on image #{image.id}"
    end

    test "removing a vote the user never cast still succeeds, logging a plain vote" do
      # With no upvote or downvote deleted, the type derivation falls through to
      # the neutral "vote".
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()
      image = image_fixture()
      refute has_vote?(image, target)

      assert {:ok, returned} =
               Images.delete_user_vote(moderator, to_string(image.id), to_string(target.id))

      assert returned.id == image.id

      log = only_moderation_log!()
      assert log.body == "Deleted vote by #{target.name} on image #{image.id}"
    end

    test "accepts bare integer ids" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()
      image = image_fixture()
      vote!(image, target, true)

      assert {:ok, returned} = Images.delete_user_vote(moderator, image.id, target.id)
      assert returned.id == image.id
      refute has_vote?(image, target)
    end

    test "a regular user is unauthorized and the vote is left intact" do
      # Image :tamper authorization runs before the user load, so a regular user
      # is denied without the vote being touched.
      user = confirmed_user_fixture()
      target = confirmed_user_fixture()
      image = image_fixture()
      vote!(image, target, true)

      assert Images.delete_user_vote(user, to_string(image.id), to_string(target.id)) ==
               {:error, :unauthorized}

      assert has_vote?(image, target)
      assert moderation_log_count() == 0
    end

    test "a regular user with a garbage user_id is still unauthorized" do
      # The :tamper check precedes the user load, so a non-castable user id never
      # reaches the not-found path for an unprivileged actor.
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.delete_user_vote(user, to_string(image.id), "not-a-number") ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an anonymous actor with a garbage user_id is unauthorized" do
      image = image_fixture()

      assert Images.delete_user_vote(nil, to_string(image.id), "not-a-number") ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown user_id is not found and writes no log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert Images.delete_user_vote(moderator, to_string(image.id), "2147483647") ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a moderator with a non-castable user_id is not found and writes no log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert Images.delete_user_vote(moderator, to_string(image.id), "not-a-number") ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "an unknown well-formed image_id is unauthorized for a non-admin actor" do
      # The image loads as nil and a regular user fails :tamper on the nil load,
      # so the missing image surfaces as unauthorized.
      user = confirmed_user_fixture()
      target = confirmed_user_fixture()

      assert Images.delete_user_vote(user, "2147483647", to_string(target.id)) ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed image_id is not found for an admin" do
      # An admin clears :tamper on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      admin = admin_user_fixture()
      target = confirmed_user_fixture()

      assert Images.delete_user_vote(admin, "2147483647", to_string(target.id)) ==
               {:error, :not_found}
    end

    test "a non-castable image_id is not found" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()

      assert Images.delete_user_vote(moderator, "not-a-number", to_string(target.id)) ==
               {:error, :not_found}
    end
  end

  describe "update_uploader/3" do
    test "a moderator reassigns the uploader, preloading the new user with awards" do
      moderator = moderator_user_fixture()
      owner = confirmed_user_fixture()
      new_owner = confirmed_user_fixture()
      image = image_fixture(user_id: owner.id)

      assert {:ok, updated} =
               Images.update_uploader(moderator, to_string(image.id), %{
                 "username" => new_owner.name
               })

      assert updated.id == image.id
      assert Repo.reload!(image).user_id == new_owner.id

      assert Ecto.assoc_loaded?(updated.user)
      assert updated.user.id == new_owner.id
      assert Ecto.assoc_loaded?(updated.user.awards)
    end

    test "an admin reassigns the uploader" do
      admin = admin_user_fixture()
      owner = confirmed_user_fixture()
      new_owner = confirmed_user_fixture()
      image = image_fixture(user_id: owner.id)

      assert {:ok, _} =
               Images.update_uploader(admin, to_string(image.id), %{"username" => new_owner.name})

      assert Repo.reload!(image).user_id == new_owner.id
    end

    test "an empty username clears the uploader to nil" do
      moderator = moderator_user_fixture()
      owner = confirmed_user_fixture()
      image = image_fixture(user_id: owner.id)

      assert {:ok, updated} =
               Images.update_uploader(moderator, to_string(image.id), %{"username" => ""})

      assert updated.id == image.id
      assert Repo.reload!(image).user_id == nil
    end

    test "reassigning writes an exact moderation log" do
      moderator = moderator_user_fixture()
      new_owner = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.update_uploader(moderator, to_string(image.id), %{
                 "username" => new_owner.name
               })

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Uploader:update"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Changed uploader of image #{image.id}"
    end

    test "clearing the uploader also succeeds and writes the same log" do
      moderator = moderator_user_fixture()
      owner = confirmed_user_fixture()
      image = image_fixture(user_id: owner.id)

      assert {:ok, _} =
               Images.update_uploader(moderator, to_string(image.id), %{"username" => ""})

      log = only_moderation_log!()
      assert log.type == "Image.Uploader:update"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Changed uploader of image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      new_owner = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, updated} =
               Images.update_uploader(moderator, image.id, %{"username" => new_owner.name})

      assert updated.id == image.id
      assert Repo.reload!(image).user_id == new_owner.id
    end

    test "an unknown username is a changeset error with the image untouched and no log" do
      moderator = moderator_user_fixture()
      owner = confirmed_user_fixture()
      image = image_fixture(user_id: owner.id)

      assert {:error, %Ecto.Changeset{}} =
               Images.update_uploader(moderator, to_string(image.id), %{
                 "username" => "no-such-user"
               })

      assert Repo.reload!(image).user_id == owner.id
      assert moderation_log_count() == 0
    end

    test "non-map params for a moderator are invalid_params with no log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert Images.update_uploader(moderator, to_string(image.id), nil) ==
               {:error, :invalid_params}

      assert moderation_log_count() == 0
    end

    test "a regular user is unauthorized on a real image and params" do
      # Authorization on :ip_address runs before the load, so a regular user is
      # denied without the image ever being touched.
      user = confirmed_user_fixture()
      new_owner = confirmed_user_fixture()
      image = image_fixture()

      assert Images.update_uploader(user, to_string(image.id), %{"username" => new_owner.name}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "a regular user with a garbage id and nil params is still unauthorized" do
      # The :ip_address authorization precedes the id parse and the params check,
      # so neither the not-found nor the invalid_params path is reached.
      user = confirmed_user_fixture()

      assert Images.update_uploader(user, "not-a-number", nil) == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an anonymous actor with a garbage id and nil params is unauthorized" do
      assert Images.update_uploader(nil, "not-a-number", nil) == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed image_id is not found and writes no log" do
      # Unlike the :hide wrappers, the load has no per-image authorization, so a
      # missing image is a plain not-found rather than unauthorized.
      moderator = moderator_user_fixture()
      new_owner = confirmed_user_fixture()

      assert Images.update_uploader(moderator, "2147483647", %{"username" => new_owner.name}) ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a moderator with a non-castable image_id is not found" do
      moderator = moderator_user_fixture()
      new_owner = confirmed_user_fixture()

      assert Images.update_uploader(moderator, "not-a-number", %{"username" => new_owner.name}) ==
               {:error, :not_found}
    end

    test "a moderator with an out-of-range image_id is not found" do
      moderator = moderator_user_fixture()
      new_owner = confirmed_user_fixture()

      assert Images.update_uploader(moderator, "99999999999999999999", %{
               "username" => new_owner.name
             }) == {:error, :not_found}
    end
  end

  describe "create_image_hide/2" do
    test "a signed-in actor hides a visible image, recording a row and bumping the count" do
      user = confirmed_user_fixture()
      image = image_fixture()
      baseline = Repo.reload!(image).hides_count

      assert {:ok, hidden} = Images.create_image_hide(actor(user), to_string(image.id))
      assert hidden.id == image.id
      assert hidden.hides_count == baseline + 1
      assert image_hide_count(image, user) == 1
    end

    test "hiding again when already hidden leaves a single row" do
      # create appends a delete before the insert, so a repeat replaces the row
      # rather than stacking, and the count nets out unchanged.
      user = confirmed_user_fixture()
      image = image_fixture()
      baseline = Repo.reload!(image).hides_count

      assert {:ok, _} = Images.create_image_hide(actor(user), to_string(image.id))
      assert {:ok, again} = Images.create_image_hide(actor(user), to_string(image.id))

      assert again.hides_count == baseline + 1
      assert image_hide_count(image, user) == 1
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, hidden} = Images.create_image_hide(actor(user), image.id)
      assert hidden.id == image.id
      assert image_hide_count(image, user) == 1
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Images.create_image_hide(actor, "not-a-number") == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Images.create_image_hide(actor, "not-a-number") == {:error, :unauthorized}
    end

    test "a non-castable id is not found" do
      assert Images.create_image_hide(actor(confirmed_user_fixture()), "not-a-number") ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert Images.create_image_hide(actor(confirmed_user_fixture()), "99999999999999999999") ==
               {:error, :not_found}
    end

    test "an unknown well-formed id is unauthorized for a regular actor" do
      # The image loads as nil and a regular actor fails :vote on the nil load, so
      # the missing image surfaces as unauthorized.
      assert Images.create_image_hide(actor(confirmed_user_fixture()), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator" do
      assert Images.create_image_hide(actor(moderator_user_fixture()), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :vote on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      assert Images.create_image_hide(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "delete_image_hide/2" do
    test "a signed-in actor unhides an image, removing the row and decrementing" do
      user = confirmed_user_fixture()
      image = image_fixture()
      baseline = Repo.reload!(image).hides_count
      {:ok, _} = Images.create_image_hide(actor(user), to_string(image.id))
      assert image_hide_count(image, user) == 1

      assert {:ok, unhidden} = Images.delete_image_hide(actor(user), to_string(image.id))
      assert unhidden.id == image.id
      assert unhidden.hides_count == baseline
      assert image_hide_count(image, user) == 0
    end

    test "unhiding when no row exists still succeeds" do
      user = confirmed_user_fixture()
      image = image_fixture()
      baseline = Repo.reload!(image).hides_count
      assert image_hide_count(image, user) == 0

      assert {:ok, unhidden} = Images.delete_image_hide(actor(user), to_string(image.id))
      assert unhidden.id == image.id
      assert unhidden.hides_count == baseline
      assert image_hide_count(image, user) == 0
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()
      {:ok, _} = Images.create_image_hide(actor(user), image.id)

      assert {:ok, unhidden} = Images.delete_image_hide(actor(user), image.id)
      assert unhidden.id == image.id
      assert image_hide_count(image, user) == 0
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Images.delete_image_hide(actor, "not-a-number") == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Images.delete_image_hide(actor, "not-a-number") == {:error, :unauthorized}
    end

    test "a non-castable id is not found" do
      assert Images.delete_image_hide(actor(confirmed_user_fixture()), "not-a-number") ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert Images.delete_image_hide(actor(confirmed_user_fixture()), "99999999999999999999") ==
               {:error, :not_found}
    end

    test "an unknown well-formed id is unauthorized for a regular actor" do
      assert Images.delete_image_hide(actor(confirmed_user_fixture()), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      assert Images.delete_image_hide(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "load_image_for_interaction/2" do
    test "a signed-in actor loads a visible image with sources and tags preloaded" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_interaction(actor(user), to_string(image.id))
      assert loaded.id == image.id
      assert Ecto.assoc_loaded?(loaded.sources)
      assert Ecto.assoc_loaded?(loaded.tags)
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, loaded} = Images.load_image_for_interaction(actor(user), image.id)
      assert loaded.id == image.id
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Images.load_image_for_interaction(actor, "not-a-number") == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Images.load_image_for_interaction(actor, "not-a-number") == {:error, :unauthorized}
    end

    test "a non-castable id is not found" do
      assert Images.load_image_for_interaction(actor(confirmed_user_fixture()), "not-a-number") ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert Images.load_image_for_interaction(
               actor(confirmed_user_fixture()),
               "99999999999999999999"
             ) == {:error, :not_found}
    end

    test "an unknown well-formed id is unauthorized for a regular actor" do
      # The image loads as nil and a regular actor fails :vote on the nil load, so
      # the missing image surfaces as unauthorized.
      assert Images.load_image_for_interaction(actor(confirmed_user_fixture()), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator" do
      assert Images.load_image_for_interaction(actor(moderator_user_fixture()), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :vote on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      assert Images.load_image_for_interaction(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "create_fave/2" do
    test "records a fave and an implicit upvote, bumping faves_count and score" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score
      base_faves = Repo.reload!(image).faves_count

      assert {:ok, faved} = Images.create_fave(image, user)
      assert faved.id == image.id
      assert faved.faves_count == base_faves + 1
      assert faved.score == base_score + 1

      assert fave_count(image, user) == 1
      assert %ImageVote{up: true} = vote_row(image, user)
    end

    test "replaces an existing downvote with the fave's upvote" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score

      vote!(image, user, false)
      assert %ImageVote{up: false} = vote_row(image, user)

      assert {:ok, faved} = Images.create_fave(image, user)
      assert %ImageVote{up: true} = vote_row(image, user)
      assert faved.score == base_score + 1
    end

    test "faving again when already faved stays at a single fave row" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_faves = Repo.reload!(image).faves_count

      assert {:ok, _} = Images.create_fave(image, user)
      assert {:ok, again} = Images.create_fave(image, user)

      assert fave_count(image, user) == 1
      assert again.faves_count == base_faves + 1
    end
  end

  describe "delete_fave/2" do
    test "removes the fave but keeps the upvote, dropping faves_count and leaving score" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score
      base_faves = Repo.reload!(image).faves_count

      {:ok, faved} = Images.create_fave(image, user)
      assert fave_count(image, user) == 1

      assert {:ok, unfaved} = Images.delete_fave(image, user)
      assert unfaved.id == image.id
      assert fave_count(image, user) == 0
      assert unfaved.faves_count == base_faves
      # The implicit upvote survives, so the score stays where the fave put it.
      assert unfaved.score == base_score + 1
      assert %ImageVote{up: true} = vote_row(image, user)
      assert faved.score == unfaved.score
    end

    test "unfaving when no fave exists still succeeds" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_faves = Repo.reload!(image).faves_count
      assert fave_count(image, user) == 0

      assert {:ok, unfaved} = Images.delete_fave(image, user)
      assert unfaved.id == image.id
      assert fave_count(image, user) == 0
      assert unfaved.faves_count == base_faves
    end
  end

  describe "create_vote/3" do
    test "an upvote records the row and bumps score and upvotes_count" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score
      base_upvotes = Repo.reload!(image).upvotes_count

      assert {:ok, voted} = Images.create_vote(image, user, true)
      assert voted.id == image.id
      assert voted.score == base_score + 1
      assert voted.upvotes_count == base_upvotes + 1
      assert %ImageVote{up: true} = vote_row(image, user)
    end

    test "a downvote records the row and drops score" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score
      base_downvotes = Repo.reload!(image).downvotes_count

      assert {:ok, voted} = Images.create_vote(image, user, false)
      assert voted.score == base_score - 1
      assert voted.downvotes_count == base_downvotes + 1
      assert %ImageVote{up: false} = vote_row(image, user)
    end

    test "revoting flips an existing downvote to an upvote in a single row" do
      # From the downvoted state the score swings up by two (the downvote is
      # removed and an upvote added), ending one above the baseline.
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score

      vote!(image, user, false)
      assert %ImageVote{up: false} = vote_row(image, user)
      assert Repo.reload!(image).score == base_score - 1

      assert {:ok, voted} = Images.create_vote(image, user, true)
      # get_by raises on more than one row, so a returned struct confirms a
      # single vote row survived the flip.
      assert %ImageVote{up: true} = vote_row(image, user)
      assert voted.score == base_score + 1
    end
  end

  describe "delete_vote/2" do
    test "removing an upvote restores the score" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score
      {:ok, _} = Images.create_vote(image, user, true)

      assert {:ok, unvoted} = Images.delete_vote(image, user)
      assert unvoted.id == image.id
      assert vote_row(image, user) == nil
      assert unvoted.score == base_score
    end

    test "removing a downvote restores the score" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score
      vote!(image, user, false)

      assert {:ok, unvoted} = Images.delete_vote(image, user)
      assert vote_row(image, user) == nil
      assert unvoted.score == base_score
    end

    test "unvoting when no vote exists still succeeds" do
      user = confirmed_user_fixture()
      image = image_fixture()
      base_score = Repo.reload!(image).score
      refute has_vote?(image, user)

      assert {:ok, unvoted} = Images.delete_vote(image, user)
      assert unvoted.id == image.id
      assert unvoted.score == base_score
      refute has_vote?(image, user)
    end
  end

  describe "hide_image/3" do
    test "a moderator hides the image, persisting the reason" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, hidden} =
               Images.hide_image(moderator, to_string(image.id), %{
                 "deletion_reason" => "Rule #0"
               })

      assert hidden.id == image.id
      assert hidden.hidden_from_users

      reloaded = Repo.reload!(image)
      assert reloaded.hidden_from_users
      assert reloaded.deletion_reason == "Rule #0"
    end

    test "an admin hides the image" do
      admin = admin_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.hide_image(admin, to_string(image.id), %{"deletion_reason" => "Rule #0"})

      assert Repo.reload!(image).hidden_from_users
    end

    test "hiding writes an exact moderation log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, _} =
               Images.hide_image(moderator, to_string(image.id), %{
                 "deletion_reason" => "Rule #0"
               })

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Delete:create"
      assert log.subject_path == "/images/#{image.id}"
      assert log.body == "Deleted image #{image.id} (Rule #0)"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, hidden} =
               Images.hide_image(moderator, image.id, %{"deletion_reason" => "Rule #0"})

      assert hidden.id == image.id
    end

    test "a blank reason is hide_failed with the image left visible and no log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert Images.hide_image(moderator, to_string(image.id), %{"deletion_reason" => ""}) ==
               {:error, :hide_failed}

      refute Repo.reload!(image).hidden_from_users
      assert moderation_log_count() == 0
    end

    test "a regular user cannot hide the image and it stays visible" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.hide_image(user, to_string(image.id), %{"deletion_reason" => "Rule #0"}) ==
               {:error, :unauthorized}

      refute Repo.reload!(image).hidden_from_users
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot hide the image" do
      image = image_fixture()

      assert Images.hide_image(nil, to_string(image.id), %{"deletion_reason" => "Rule #0"}) ==
               {:error, :unauthorized}

      refute Repo.reload!(image).hidden_from_users
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      moderator = moderator_user_fixture()

      assert Images.hide_image(moderator, "2147483647", %{"deletion_reason" => "Rule #0"}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      admin = admin_user_fixture()

      assert Images.hide_image(admin, "2147483647", %{"deletion_reason" => "Rule #0"}) ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.hide_image(moderator, "not-a-number", %{"deletion_reason" => "Rule #0"}) ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.hide_image(moderator, "99999999999999999999", %{
               "deletion_reason" => "Rule #0"
             }) == {:error, :not_found}
    end
  end

  describe "update_hide_reason/3" do
    test "a moderator updates the reason on a hidden image" do
      moderator = moderator_user_fixture()
      hidden = hidden_image_fixture("Original reason")

      assert {:ok, updated} =
               Images.update_hide_reason(moderator, to_string(hidden.id), %{
                 "deletion_reason" => "Better reason"
               })

      assert updated.id == hidden.id
      assert Repo.reload!(hidden).deletion_reason == "Better reason"
    end

    test "updating the reason writes an exact moderation log with the new reason" do
      moderator = moderator_user_fixture()
      hidden = hidden_image_fixture("Original reason")

      assert {:ok, _} =
               Images.update_hide_reason(moderator, to_string(hidden.id), %{
                 "deletion_reason" => "Better reason"
               })

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Delete:update"
      assert log.subject_path == "/images/#{hidden.id}"
      assert log.body == "Changed deletion reason of #{hidden.id} (Better reason)"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      hidden = hidden_image_fixture()

      assert {:ok, updated} =
               Images.update_hide_reason(moderator, hidden.id, %{"deletion_reason" => "New"})

      assert updated.id == hidden.id
    end

    test "a visible image is not_deleted with no log" do
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert Images.update_hide_reason(moderator, to_string(image.id), %{
               "deletion_reason" => "New"
             }) == {:error, :not_deleted}

      assert moderation_log_count() == 0
    end

    test "a regular user on a visible image is unauthorized, not not_deleted" do
      # Authorization runs before the hidden-state check, so a regular user fails
      # :hide and never reaches the not_deleted branch.
      user = confirmed_user_fixture()
      image = image_fixture()

      assert Images.update_hide_reason(user, to_string(image.id), %{"deletion_reason" => "New"}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "a blank reason on a hidden image is a changeset error with the reason unchanged" do
      moderator = moderator_user_fixture()
      hidden = hidden_image_fixture("Keep me")

      assert {:error, %Ecto.Changeset{}} =
               Images.update_hide_reason(moderator, to_string(hidden.id), %{
                 "deletion_reason" => ""
               })

      assert Repo.reload!(hidden).deletion_reason == "Keep me"
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      moderator = moderator_user_fixture()

      assert Images.update_hide_reason(moderator, "2147483647", %{"deletion_reason" => "New"}) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      admin = admin_user_fixture()

      assert Images.update_hide_reason(admin, "2147483647", %{"deletion_reason" => "New"}) ==
               {:error, :not_found}

      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_hide_reason(moderator, "not-a-number", %{"deletion_reason" => "New"}) ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.update_hide_reason(moderator, "99999999999999999999", %{
               "deletion_reason" => "New"
             }) == {:error, :not_found}
    end
  end

  describe "unhide_image/2" do
    test "a moderator restores a hidden image" do
      moderator = moderator_user_fixture()
      hidden = hidden_image_fixture()

      assert {:ok, restored} = Images.unhide_image(moderator, to_string(hidden.id))
      assert restored.id == hidden.id
      refute restored.hidden_from_users
      refute Repo.reload!(hidden).hidden_from_users
    end

    test "an admin restores a hidden image" do
      admin = admin_user_fixture()
      hidden = hidden_image_fixture()

      assert {:ok, _} = Images.unhide_image(admin, to_string(hidden.id))
      refute Repo.reload!(hidden).hidden_from_users
    end

    test "restoring writes an exact moderation log" do
      moderator = moderator_user_fixture()
      hidden = hidden_image_fixture()

      assert {:ok, _} = Images.unhide_image(moderator, to_string(hidden.id))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Image.Delete:delete"
      assert log.subject_path == "/images/#{hidden.id}"
      assert log.body == "Restored image #{hidden.id}"
    end

    test "restoring an already-visible image still succeeds and logs" do
      # The engine's fall-through clause returns {:ok, image} for a non-hidden
      # image, so the wrapper reports success and writes the restore log even
      # though nothing changed.
      moderator = moderator_user_fixture()
      image = image_fixture()

      assert {:ok, restored} = Images.unhide_image(moderator, to_string(image.id))
      assert restored.id == image.id
      refute Repo.reload!(image).hidden_from_users

      log = only_moderation_log!()
      assert log.type == "Image.Delete:delete"
      assert log.body == "Restored image #{image.id}"
    end

    test "accepts an integer id" do
      moderator = moderator_user_fixture()
      hidden = hidden_image_fixture()

      assert {:ok, restored} = Images.unhide_image(moderator, hidden.id)
      assert restored.id == hidden.id
    end

    test "a regular user cannot restore a hidden image and it stays hidden" do
      user = confirmed_user_fixture()
      hidden = hidden_image_fixture()

      assert Images.unhide_image(user, to_string(hidden.id)) == {:error, :unauthorized}
      assert Repo.reload!(hidden).hidden_from_users
      assert moderation_log_count() == 0
    end

    test "an anonymous actor cannot restore a hidden image" do
      hidden = hidden_image_fixture()

      assert Images.unhide_image(nil, to_string(hidden.id)) == {:error, :unauthorized}
      assert Repo.reload!(hidden).hidden_from_users
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown well-formed id is unauthorized and writes no log" do
      moderator = moderator_user_fixture()

      assert Images.unhide_image(moderator, "2147483647") == {:error, :unauthorized}
      assert moderation_log_count() == 0
    end

    test "an admin with an unknown well-formed id is not found and writes no log" do
      admin = admin_user_fixture()

      assert Images.unhide_image(admin, "2147483647") == {:error, :not_found}
      assert moderation_log_count() == 0
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()

      assert Images.unhide_image(moderator, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      moderator = moderator_user_fixture()

      assert Images.unhide_image(moderator, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "update_sources/3" do
    test "a signed-in actor adds a source, recording an attributed change and bumping stats" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, result} =
               Images.update_sources(
                 actor(user),
                 to_string(image.id),
                 add_source_attrs("https://example.com/art")
               )

      assert result.image.id == image.id
      assert result.added == ["https://example.com/art"]
      assert result.removed == []
      assert result.source_change_count == 1

      change = Repo.one(from s in SourceChange, where: s.image_id == ^image.id)
      assert change.user_id == user.id
      assert change.added == true

      assert Repo.reload!(user).metadata_updates_count == 1
    end

    test "an anonymous fingerprinted actor records a change with no user" do
      image = image_fixture()

      assert {:ok, result} =
               Images.update_sources(
                 actor(nil),
                 to_string(image.id),
                 add_source_attrs("https://example.com/anon")
               )

      assert result.added == ["https://example.com/anon"]

      change = Repo.one(from s in SourceChange, where: s.image_id == ^image.id)
      assert change.user_id == nil
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, result} =
               Images.update_sources(
                 actor(user),
                 image.id,
                 add_source_attrs("https://example.com/i")
               )

      assert result.image.id == image.id
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Images.update_sources(actor, "not-a-number", add_source_attrs("https://x.test")) ==
               {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Images.update_sources(actor, "not-a-number", add_source_attrs("https://x.test")) ==
               {:error, :unauthorized}
    end

    test "a hidden image is unauthorized and records no change" do
      # edit_metadata requires a non-hidden image, so a hidden one fails
      # authorization for a signed-in actor.
      user = confirmed_user_fixture()
      hidden = hidden_image_fixture()

      assert Images.update_sources(
               actor(user),
               to_string(hidden.id),
               add_source_attrs("https://x.test")
             ) == {:error, :unauthorized}

      assert source_change_row_count(hidden) == 0
    end

    test "more than 15 sources is a changeset error with no change recorded" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Images.update_sources(actor(user), to_string(image.id), many_source_attrs(16))

      assert source_change_row_count(image) == 0
    end

    test "an unknown well-formed id is unauthorized for a regular actor" do
      # The image loads as nil and a regular actor fails :edit_metadata on the nil
      # load, so the missing image surfaces as unauthorized.
      assert Images.update_sources(
               actor(confirmed_user_fixture()),
               "2147483647",
               add_source_attrs("https://x.test")
             ) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :edit_metadata on the nil load via the blanket ability
      # rule, then the image presence check fails, so it is not found.
      assert Images.update_sources(
               actor(admin_user_fixture()),
               "2147483647",
               add_source_attrs("https://x.test")
             ) == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.update_sources(
               actor(confirmed_user_fixture()),
               "not-a-number",
               add_source_attrs("https://x.test")
             ) == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert Images.update_sources(
               actor(confirmed_user_fixture()),
               "99999999999999999999",
               add_source_attrs("https://x.test")
             ) == {:error, :not_found}
    end
  end

  describe "update_tags/3" do
    setup do
      # The shared attribution fixture's anonymous identity (i:<ip>) is not rolled
      # back by the SQL sandbox and accumulates across runs, so clear it before
      # each test. Signed-in tests use fresh users, whose u:<id> bucket starts
      # empty on its own.
      reset_tag_change_limits()
      :ok
    end

    test "a signed-in actor changes tags, recording an attributed change and bumping stats" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, result} =
               Images.update_tags(
                 actor(user),
                 to_string(image.id),
                 tag_attrs("safe", "safe, added test tag, other added tag")
               )

      assert result.image.id == image.id
      assert Enum.sort(Enum.map(result.added, & &1.name)) == ["added test tag", "other added tag"]
      assert result.removed == []
      assert result.tag_change_count >= 1
      assert result.tag_change_tag_count >= 1

      assert tag_names(image) == ["added test tag", "other added tag", "safe"]

      change = Repo.one(from tc in TagChange, where: tc.image_id == ^image.id)
      assert change.user_id == user.id

      assert Repo.reload!(user).metadata_updates_count == 1
    end

    test "an anonymous fingerprinted actor records a change with no user" do
      image = image_fixture()

      assert {:ok, _result} =
               Images.update_tags(
                 actor(nil),
                 to_string(image.id),
                 tag_attrs("safe", "safe, added test tag, other added tag")
               )

      change = Repo.one(from tc in TagChange, where: tc.image_id == ^image.id)
      assert change.user_id == nil
    end

    test "accepts an integer id" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:ok, result} =
               Images.update_tags(
                 actor(user),
                 image.id,
                 tag_attrs("safe", "safe, added test tag, other added tag")
               )

      assert result.image.id == image.id
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Images.update_tags(actor, "not-a-number", tag_attrs("safe", "safe, a, b")) ==
               {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Images.update_tags(actor, "not-a-number", tag_attrs("safe", "safe, a, b")) ==
               {:error, :unauthorized}
    end

    test "an image with tag editing disabled is unauthorized and records no change" do
      user = confirmed_user_fixture()
      image = image_fixture(tag_editing_allowed: false)

      assert Images.update_tags(
               actor(user),
               to_string(image.id),
               tag_attrs("safe", "safe, added test tag, other added tag")
             ) == {:error, :unauthorized}

      refute Repo.exists?(from tc in TagChange, where: tc.image_id == ^image.id)
    end

    test "reducing below the minimum tag count is a changeset error with tags unchanged" do
      user = confirmed_user_fixture()
      image = image_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Images.update_tags(
                 actor(user),
                 to_string(image.id),
                 tag_attrs("safe", "safe, one more")
               )

      assert tag_names(image) == ["safe"]
      refute Repo.exists?(from tc in TagChange, where: tc.image_id == ^image.id)
    end

    test "exceeding the tag-change rate limit rolls the transaction back" do
      user = confirmed_user_fixture()
      image = image_fixture()
      ip = %Postgrex.INET{address: {203, 0, 113, 1}, netmask: 32}

      # Fill the user's tag bucket to the 50-change limit so the next multi-tag
      # update trips check_limits. The counter carries a 10-minute TTL that the
      # SQL sandbox does not roll back, so clear it afterward.
      :ok = Limits.update_tag_count_after_update(user, ip, 50)
      on_exit(fn -> reset_tag_change_limits(user: user, ip: ip) end)

      assert Images.update_tags(
               actor(user),
               to_string(image.id),
               tag_attrs("safe", "safe, added test tag, other added tag")
             ) == {:error, :rate_limited}

      assert tag_names(image) == ["safe"]
      refute Repo.exists?(from tc in TagChange, where: tc.image_id == ^image.id)
    end

    test "an unknown well-formed id is unauthorized for a regular actor" do
      # The image loads as nil and a regular actor fails :edit_metadata on the nil
      # load, so the missing image surfaces as unauthorized.
      assert Images.update_tags(
               actor(confirmed_user_fixture()),
               "2147483647",
               tag_attrs("safe", "safe, a, b")
             ) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :edit_metadata on the nil load via the blanket ability
      # rule, then the image presence check fails, so it is not found.
      assert Images.update_tags(
               actor(admin_user_fixture()),
               "2147483647",
               tag_attrs("safe", "safe, a, b")
             ) == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.update_tags(
               actor(confirmed_user_fixture()),
               "not-a-number",
               tag_attrs("safe", "safe, a, b")
             ) == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert Images.update_tags(
               actor(confirmed_user_fixture()),
               "99999999999999999999",
               tag_attrs("safe", "safe, a, b")
             ) == {:error, :not_found}
    end
  end

  # Records one tag change against `image` (adding two tags), returning the
  # image. Produces a single tag_changes row carrying two tag_change_tags.
  defp record_tag_change(image) do
    user = confirmed_user_fixture()
    reset_tag_change_limits()

    {:ok, _} =
      Images.update_tags(actor(user), to_string(image.id), tag_attrs("safe", "safe, alpha, beta"))

    image
  end

  # The compiled filter body the web layer produces for a viewer with no active
  # filter: an empty tag_ids exclusion plus a pair of match_none clauses, so it
  # excludes nothing.
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

  defp index_scope(user \\ nil) do
    %Scope{user: user, filter: default_filter()}
  end

  defp minutes_ago(minutes) do
    DateTime.utc_now()
    |> DateTime.add(-minutes * 60, :second)
    |> DateTime.truncate(:second)
  end

  # Waits for the background upload process a successful upload spawns to exit.
  # It shares the test process's sandbox connection, so letting it outlive the
  # test leaves it retrying against a dead owner. The spawned process is our
  # direct child.
  defp await_async_upload do
    test_pid = self()

    for pid <- Process.list(), Process.info(pid, :parent) == {:parent, test_pid} do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> raise "async upload process #{inspect(pid)} did not exit"
      end
    end

    :ok
  end

  describe "load_image_for_show/2" do
    test "an anonymous viewer loads a visible image with zero change counts" do
      image = image_fixture()

      assert {:ok, result} = Images.load_image_for_show(nil, to_string(image.id))
      assert result.image.id == image.id
      assert result.tag_change_count == 0
      assert result.tag_change_tag_count == 0
      assert result.source_change_count == 0
    end

    test "the change counts reflect recorded tag and source changes" do
      image = image_fixture()
      record_tag_change(image)
      source_change_fixture(image)
      source_change_fixture(image)

      assert {:ok, result} = Images.load_image_for_show(nil, to_string(image.id))
      assert result.tag_change_count == 1
      assert result.tag_change_tag_count == 2
      assert result.source_change_count == 2
    end

    test "the show preloads are populated on the loaded image" do
      image = image_fixture(sources: ["https://example.com/a"])

      assert {:ok, %{image: loaded}} = Images.load_image_for_show(nil, to_string(image.id))
      assert Ecto.assoc_loaded?(loaded.tags)
      assert Ecto.assoc_loaded?(loaded.sources)
      assert Ecto.assoc_loaded?(loaded.locked_tags)
    end

    test "accepts an integer id" do
      image = image_fixture()

      assert {:ok, %{image: loaded}} = Images.load_image_for_show(nil, image.id)
      assert loaded.id == image.id
    end

    test "a hidden image still loads for an anonymous viewer" do
      # Viewing carries no authorization here; a hidden image renders its
      # deleted notice rather than being withheld.
      image = image_fixture(hidden_from_users: true)

      assert {:ok, %{image: loaded}} = Images.load_image_for_show(nil, to_string(image.id))
      assert loaded.id == image.id
    end

    test "a hidden duplicate is redirected for an anonymous viewer" do
      # A merged image is hidden from users; a viewer who cannot :show the
      # hidden image is redirected to its duplicate rather than shown the notice.
      original = image_fixture()
      duplicate = image_fixture(duplicate_id: original.id, hidden_from_users: true)

      assert {:duplicate_of, loaded} = Images.load_image_for_show(nil, to_string(duplicate.id))
      assert loaded.id == duplicate.id
      assert loaded.duplicate_id == original.id
    end

    test "a non-hidden duplicate is shown to an anonymous viewer" do
      # The duplicate branch only fires when the viewer cannot :show the image;
      # a duplicate that is not hidden is still viewable, so it loads normally.
      original = image_fixture()
      duplicate = image_fixture(duplicate_id: original.id)

      assert {:ok, %{image: loaded}} = Images.load_image_for_show(nil, to_string(duplicate.id))
      assert loaded.id == duplicate.id
    end

    test "a hidden duplicate loads normally for a moderator who can show it" do
      moderator = moderator_user_fixture()
      original = image_fixture()
      duplicate = image_fixture(duplicate_id: original.id, hidden_from_users: true)

      assert {:ok, %{image: loaded}} =
               Images.load_image_for_show(moderator, to_string(duplicate.id))

      assert loaded.id == duplicate.id
    end

    test "an unknown well-formed id is not found for an anonymous viewer" do
      # There is no authorization on this loader, so a missing image is a plain
      # not found for every actor rather than an unauthorized.
      assert Images.load_image_for_show(nil, "2147483647") == {:error, :not_found}
    end

    test "an unknown well-formed id is not found for an admin" do
      assert Images.load_image_for_show(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert Images.load_image_for_show(nil, "not-a-number") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert Images.load_image_for_show(nil, "99999999999999999999") == {:error, :not_found}
    end
  end

  describe "load_image_page/3" do
    test "assembles the page struct for a signed-in viewer" do
      user = confirmed_user_fixture()
      image = image_fixture()

      page = Images.load_image_page(user, image, page: 1, page_size: 25)

      assert %ImagePage{} = page
      assert page.image.id == image.id
      assert %Scrivener.Page{} = page.comments
      assert is_boolean(page.watching)
      assert is_list(page.user_galleries)
      assert is_list(page.interactions)
      assert %Ecto.Changeset{} = page.comment_changeset
      assert %Ecto.Changeset{} = page.image_changeset
    end

    test "assembles the page struct for an anonymous viewer" do
      image = image_fixture()

      page = Images.load_image_page(nil, image, page: 1, page_size: 25)

      assert %ImagePage{} = page
      refute page.watching
      assert page.user_galleries == []
      assert page.interactions == []
    end

    test "watching is true once the viewer is subscribed" do
      user = confirmed_user_fixture()
      image = image_fixture()
      {:ok, _} = Images.create_subscription(image, user)

      page = Images.load_image_page(user, image, page: 1, page_size: 25)

      assert page.watching
    end

    test "user_galleries pairs each of the viewer's galleries with image membership" do
      user = confirmed_user_fixture()
      image = image_fixture()
      containing = gallery_fixture(user)
      empty = gallery_fixture(user)
      {:ok, _} = Galleries.add_image_to_gallery(containing, image)

      page = Images.load_image_page(user, image, page: 1, page_size: 25)

      memberships =
        Map.new(page.user_galleries, fn {gallery, member?} -> {gallery.id, member?} end)

      assert memberships[containing.id] == true
      assert memberships[empty.id] == false
    end

    test "loading the page clears the viewer's image notification" do
      user = confirmed_user_fixture()
      image = image_fixture()
      arrange_comment_notification(image, user)
      assert comment_notification?(image, user)

      Images.load_image_page(user, image, page: 1, page_size: 25)

      refute comment_notification?(image, user)
    end

    test "an oldest-first jump-to-last viewer lands on the final comment page" do
      user =
        confirmed_user_fixture()
        |> Ecto.Changeset.change(comments_newest_first: false, comments_always_jump_to_last: true)
        |> Repo.update!()

      image = image_fixture()
      author = confirmed_user_fixture()
      for _ <- 1..3, do: comment_fixture(image, author)

      page = Images.load_image_page(user, image, page: 1, page_size: 2)

      # Three comments over a page size of two put the newest on the second page.
      assert page.comments.page_number == 2
    end

    test "a viewer without the jump preference stays on the requested page" do
      user = confirmed_user_fixture()
      image = image_fixture()
      author = confirmed_user_fixture()
      for _ <- 1..3, do: comment_fixture(image, author)

      page = Images.load_image_page(user, image, page: 1, page_size: 2)

      assert page.comments.page_number == 1
    end
  end

  describe "load_new_image/1" do
    test "a normal actor gets the upload form changeset" do
      assert {:ok, %Ecto.Changeset{}} = Images.load_new_image(actor(confirmed_user_fixture()))
    end

    test "an anonymous actor gets the upload form changeset" do
      assert {:ok, %Ecto.Changeset{}} = Images.load_new_image(actor(nil))
    end

    test "a banned actor may not reach the form" do
      assert Images.load_new_image(actor(confirmed_user_fixture(), ban: @ban)) == {:error, :ban}
    end

    test "a banned actor is rejected even with a fingerprint" do
      # load_new_image only checks the ban, so a fingerprint does not rescue a
      # banned actor.
      actor = actor(confirmed_user_fixture(), ban: @ban, fingerprint: "d015c342859dde3")

      assert Images.load_new_image(actor) == {:error, :ban}
    end
  end

  describe "upload_image/2" do
    test "a normal actor uploads an image and the row exists" do
      actor = actor(confirmed_user_fixture())

      assert {:ok, %{image: %Image{} = image, upload_pid: pid}} =
               Images.upload_image(actor, %{
                 "image" => png_upload(),
                 "tag_input" => "safe, solo, pony"
               })

      # The background upload process finishes the persist/repair work against
      # the Repo; in an async case it owns no sandbox connection, so grant it the
      # test's before awaiting its exit.
      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)

      assert Repo.get(Image, image.id)
      await_async_upload()
    end

    test "a banned actor may not upload" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Images.upload_image(actor, %{"image" => png_upload(), "tag_input" => "safe"}) ==
               {:error, :ban}
    end

    test "an actor with no fingerprint may not upload" do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Images.upload_image(actor, %{"image" => png_upload(), "tag_input" => "safe"}) ==
               {:error, :unauthorized}
    end

    test "a ban outranks a missing fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban, fingerprint: nil)

      assert Images.upload_image(actor, %{"image" => png_upload(), "tag_input" => "safe"}) ==
               {:error, :ban}
    end
  end

  describe "load_image_index/1" do
    @describetag :search

    setup do
      Search.clear_index!(Image)
      :ok
    end

    test "a visible older image appears for an anonymous scope, with tags preloaded" do
      image = image_fixture(created_at: minutes_ago(4))
      SearchHelpers.reindex_all!(Image)

      page = Images.load_image_index(index_scope())

      assert %Scrivener.Page{} = page
      ids = Enum.map(page.entries, & &1.id)
      assert image.id in ids

      entry = Enum.find(page.entries, &(&1.id == image.id))
      assert Ecto.assoc_loaded?(entry.tags)
    end

    test "a recent image is held back by the front-page upload delay" do
      image = image_fixture(created_at: minutes_ago(1))
      SearchHelpers.reindex_all!(Image)

      page = Images.load_image_index(index_scope())

      refute image.id in Enum.map(page.entries, & &1.id)
    end
  end
end
