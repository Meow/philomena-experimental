defmodule Philomena.ImagesTest do
  use Philomena.DataCase, async: true

  import Ecto.Query

  alias Philomena.Images
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Notifications
  alias Philomena.Notifications.ImageCommentNotification
  alias Philomena.Notifications.ImageMergeNotification

  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures
  import Philomena.AttributionFixtures
  import Philomena.CommentsFixtures

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
end
