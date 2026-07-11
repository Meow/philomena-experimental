defmodule Philomena.ImagesTest do
  use Philomena.DataCase, async: true

  import Ecto.Query

  alias Philomena.ImageFaves
  alias Philomena.ImageHides
  alias Philomena.Images
  alias Philomena.ImageVotes
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Notifications
  alias Philomena.Notifications.ImageCommentNotification
  alias Philomena.Notifications.ImageMergeNotification
  alias Philomena.SourceChanges.SourceChange

  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures
  import Philomena.AttributionFixtures
  import Philomena.CommentsFixtures
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
end
