defmodule Philomena.BadgesTest do
  @moduledoc """
  Context-level tests for the actor-first badge-award loaders and writers on
  `Philomena.Badges`.

  Awarding is admin/moderator-only (the `:create` permission on `Award`); these
  pin that matrix, the not-found shapes for unknown slugs and award ids, and the
  byte-exact moderation logs each write emits (type, body, and subject path),
  including that failure and authorization paths write none.
  """

  use Philomena.DataCase, async: true

  import Philomena.BadgesFixtures
  import Philomena.UsersFixtures

  alias Philomena.Badges
  alias Philomena.Badges.Award
  alias Philomena.Badges.Badge
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo

  @pagination %{page_number: 1, page_size: 25}

  # A profile user with an all-unreserved slug, so the moderation-log
  # subject_path is byte-identical to "/profiles/<slug>" with no percent-encoding.
  defp awardee_fixture do
    confirmed_user_fixture(%{name: "awardee#{System.unique_integer([:positive])}"})
  end

  defp moderation_logs, do: Repo.all(ModerationLog)

  defp no_moderation_logs! do
    assert Repo.aggregate(ModerationLog, :count) == 0
  end

  describe "awardable_badges/0" do
    test "returns the enabled badges ordered by title and excludes disabled ones" do
      beta = badge_fixture(%{title: "Beta Badge"})
      alpha = badge_fixture(%{title: "Alpha Badge"})
      _disabled = badge_fixture(%{title: "Gamma Badge", disable_award: true})

      titles = Badges.awardable_badges() |> Enum.map(& &1.title)

      # Ordered ascending by title, and the disabled badge is absent.
      assert Enum.find_index(titles, &(&1 == alpha.title)) <
               Enum.find_index(titles, &(&1 == beta.title))

      refute "Gamma Badge" in titles
    end
  end

  describe "load_award_for_new/2" do
    test "an admin gets the profile user and a changeset" do
      user = awardee_fixture()

      assert {:ok, {loaded_user, %Ecto.Changeset{data: %Award{}}}} =
               Badges.load_award_for_new(admin_user_fixture(), user.slug)

      assert loaded_user.id == user.id
    end

    test "a regular user may not award badges" do
      user = awardee_fixture()

      assert Badges.load_award_for_new(confirmed_user_fixture(), user.slug) ==
               {:error, :unauthorized}
    end

    test "a permitted actor naming an unknown slug is not-found" do
      assert Badges.load_award_for_new(admin_user_fixture(), "no-such-user") ==
               {:error, :not_found}
    end
  end

  describe "award_badge/3" do
    test "an admin awards a badge, inserting the award and a byte-exact create log" do
      admin = admin_user_fixture()
      user = awardee_fixture()
      badge = badge_fixture(%{title: "Test Award Badge"})

      assert {:ok, {loaded_user, %Award{} = award}} =
               Badges.award_badge(admin, user.slug, %{"badge_id" => badge.id})

      assert loaded_user.id == user.id
      assert Repo.get(Award, award.id).user_id == user.id

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Profile.Award:create"
      assert log.body == "Awarded badge 'Test Award Badge' to #{user.name}"
      assert log.subject_path == "/profiles/#{user.slug}"
    end

    test "a rejected award writes no log and returns the user with the changeset" do
      user = awardee_fixture()

      # No badge_id, so the award changeset is invalid.
      assert {:error, {loaded_user, %Ecto.Changeset{} = changeset}} =
               Badges.award_badge(admin_user_fixture(), user.slug, %{})

      assert loaded_user.id == user.id
      refute changeset.valid?
      assert Repo.aggregate(Award, :count) == 0
      no_moderation_logs!()
    end

    test "a regular user is unauthorized and writes no log" do
      user = awardee_fixture()
      badge = badge_fixture()

      assert Badges.award_badge(confirmed_user_fixture(), user.slug, %{"badge_id" => badge.id}) ==
               {:error, :unauthorized}

      assert Repo.aggregate(Award, :count) == 0
      no_moderation_logs!()
    end
  end

  describe "load_award_for_edit/3" do
    test "an admin loads the award and a changeset" do
      admin = admin_user_fixture()
      user = awardee_fixture()
      award = badge_award_fixture(admin, user)

      assert {:ok, {loaded_user, loaded_award, %Ecto.Changeset{}}} =
               Badges.load_award_for_edit(admin, user.slug, "#{award.id}")

      assert loaded_user.id == user.id
      assert loaded_award.id == award.id
    end

    test "a non-castable award id is not-found" do
      user = awardee_fixture()

      assert Badges.load_award_for_edit(admin_user_fixture(), user.slug, "abc") ==
               {:error, :not_found}
    end

    test "an unknown award id is not-found" do
      user = awardee_fixture()

      assert Badges.load_award_for_edit(admin_user_fixture(), user.slug, "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "update_badge_award/4" do
    test "an admin updates an award and writes a byte-exact update log" do
      admin = admin_user_fixture()
      user = awardee_fixture()
      badge = badge_fixture(%{title: "Test Award Badge"})
      award = badge_award_fixture(admin, user, badge)

      assert {:ok, {loaded_user, updated}} =
               Badges.update_badge_award(admin, user.slug, "#{award.id}", %{"label" => "Best"})

      assert loaded_user.id == user.id
      assert Repo.get(Award, updated.id).label == "Best"

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Profile.Award:update"
      assert log.body == "Updated award of badge 'Test Award Badge' on #{user.name}"
      assert log.subject_path == "/profiles/#{user.slug}"
    end
  end

  describe "revoke_badge_award/3" do
    test "an admin revokes an award, deleting it and writing a byte-exact delete log" do
      admin = admin_user_fixture()
      user = awardee_fixture()
      badge = badge_fixture(%{title: "Test Award Badge"})
      award = badge_award_fixture(admin, user, badge)

      assert {:ok, {loaded_user, revoked}} =
               Badges.revoke_badge_award(admin, user.slug, "#{award.id}")

      assert loaded_user.id == user.id
      assert revoked.id == award.id
      assert Repo.get(Award, award.id) == nil

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Profile.Award:delete"
      assert log.body == "Removed badge 'Test Award Badge' from #{user.name}"
      assert log.subject_path == "/profiles/#{user.slug}"
    end

    test "a regular user is unauthorized and writes no log" do
      admin = admin_user_fixture()
      user = awardee_fixture()
      award = badge_award_fixture(admin, user)

      assert Badges.revoke_badge_award(confirmed_user_fixture(), user.slug, "#{award.id}") ==
               {:error, :unauthorized}

      assert Repo.get(Award, award.id).id == award.id
      no_moderation_logs!()
    end
  end

  describe "load_badges/2" do
    test "an admin and a Badge-role moderator may list, others may not" do
      _badge = badge_fixture()

      assert {:ok, %Scrivener.Page{}} = Badges.load_badges(admin_user_fixture(), @pagination)

      assert {:ok, %Scrivener.Page{}} =
               Badges.load_badges(role_moderator_fixture("Badge"), @pagination)

      assert Badges.load_badges(moderator_user_fixture(), @pagination) == {:error, :unauthorized}
      assert Badges.load_badges(confirmed_user_fixture(), @pagination) == {:error, :unauthorized}
      assert Badges.load_badges(nil, @pagination) == {:error, :unauthorized}
    end

    test "the listing is ordered by title" do
      beta = badge_fixture(%{title: "Zeta Listing Badge"})
      alpha = badge_fixture(%{title: "Alpha Listing Badge"})

      assert {:ok, page} = Badges.load_badges(admin_user_fixture(), @pagination)

      titles = Enum.map(page.entries, & &1.title)

      assert Enum.find_index(titles, &(&1 == alpha.title)) <
               Enum.find_index(titles, &(&1 == beta.title))
    end
  end

  describe "new_badge/1" do
    test "an admin and a Badge-role moderator get a changeset, others do not" do
      assert {:ok, %Ecto.Changeset{data: %Badge{}}} = Badges.new_badge(admin_user_fixture())

      assert {:ok, %Ecto.Changeset{data: %Badge{}}} =
               Badges.new_badge(role_moderator_fixture("Badge"))

      assert Badges.new_badge(moderator_user_fixture()) == {:error, :unauthorized}
      assert Badges.new_badge(nil) == {:error, :unauthorized}
    end
  end

  describe "create_badge/2" do
    test "an admin creates a badge through the upload pipeline and writes a byte-exact log" do
      admin = admin_user_fixture()

      assert {:ok, %Badge{} = badge} =
               Badges.create_badge(admin, %{"title" => "Created Badge", "image" => svg_upload()})

      assert badge.title == "Created Badge"
      assert Repo.get_by(Badge, title: "Created Badge")

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Admin.Badge:create"
      assert log.body == "Created badge 'Created Badge'"
      assert log.subject_path == "/admin/badges"
    end

    test "a Badge-role moderator creates a badge" do
      assert {:ok, %Badge{}} =
               Badges.create_badge(role_moderator_fixture("Badge"), %{
                 "title" => "Mod Created Badge",
                 "image" => svg_upload()
               })
    end

    test "a plain moderator is unauthorized and writes no log" do
      assert Badges.create_badge(moderator_user_fixture(), %{
               "title" => "nope",
               "image" => svg_upload()
             }) == {:error, :unauthorized}

      refute Repo.get_by(Badge, title: "nope")
      no_moderation_logs!()
    end

    test "a missing image is a changeset error and writes no log" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Badges.create_badge(admin_user_fixture(), %{"title" => "No Image Badge"})

      refute changeset.valid?
      refute Repo.get_by(Badge, title: "No Image Badge")
      no_moderation_logs!()
    end
  end

  describe "load_badge_for_edit/2" do
    test "an admin loads the badge and a changeset" do
      badge = badge_fixture()

      assert {:ok, {loaded, %Ecto.Changeset{}}} =
               Badges.load_badge_for_edit(admin_user_fixture(), "#{badge.id}")

      assert loaded.id == badge.id
    end

    test "a plain moderator is unauthorized" do
      badge = badge_fixture()

      assert Badges.load_badge_for_edit(moderator_user_fixture(), "#{badge.id}") ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Badges.load_badge_for_edit(admin_user_fixture(), "abc") == {:error, :not_found}
    end

    test "an unknown id is not-found for a Badge-role moderator and an admin alike" do
      assert Badges.load_badge_for_edit(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}

      assert Badges.load_badge_for_edit(role_moderator_fixture("Badge"), "2147483647") ==
               {:error, :not_found}
    end
  end

  describe "update_badge/3" do
    test "an admin updates a badge and writes a byte-exact log" do
      admin = admin_user_fixture()
      badge = badge_fixture(%{title: "Before Title"})

      assert {:ok, updated} =
               Badges.update_badge(admin, "#{badge.id}", %{"title" => "After Title"})

      assert updated.title == "After Title"
      assert Repo.get(Badge, badge.id).title == "After Title"

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Admin.Badge:update"
      assert log.body == "Updated badge 'After Title'"
      assert log.subject_path == "/admin/badges"
    end

    test "a plain moderator is unauthorized and writes no log" do
      badge = badge_fixture(%{title: "Unchanged"})

      assert Badges.update_badge(moderator_user_fixture(), "#{badge.id}", %{"title" => "changed"}) ==
               {:error, :unauthorized}

      assert Repo.get(Badge, badge.id).title == "Unchanged"
      no_moderation_logs!()
    end

    test "an unknown id is not-found" do
      assert Badges.update_badge(admin_user_fixture(), "2147483647", %{"title" => "x"}) ==
               {:error, :not_found}
    end

    test "a blank title is a changeset error and writes no log" do
      badge = badge_fixture(%{title: "Keep This"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Badges.update_badge(admin_user_fixture(), "#{badge.id}", %{"title" => ""})

      refute changeset.valid?
      assert Repo.get(Badge, badge.id).title == "Keep This"
      no_moderation_logs!()
    end
  end

  describe "update_badge_image/3" do
    test "an admin updates the image through the upload pipeline and writes a byte-exact log" do
      admin = admin_user_fixture()
      badge = badge_fixture(%{title: "Image Badge"})

      assert {:ok, %Badge{}} =
               Badges.update_badge_image(admin, "#{badge.id}", %{"image" => svg_upload()})

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Admin.Badge.Image:update"
      assert log.body == "Updated image of badge 'Image Badge'"
      assert log.subject_path == "/admin/badges"
    end

    test "a plain moderator is unauthorized and writes no log" do
      badge = badge_fixture()

      assert Badges.update_badge_image(moderator_user_fixture(), "#{badge.id}", %{
               "image" => svg_upload()
             }) == {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an unknown id is not-found" do
      assert Badges.update_badge_image(admin_user_fixture(), "2147483647", %{
               "image" => svg_upload()
             }) == {:error, :not_found}
    end
  end

  describe "load_badge_users/3" do
    test "an admin loads the badge with the users who hold it" do
      admin = admin_user_fixture()
      badge = badge_fixture()
      user = awardee_fixture()
      _award = badge_award_fixture(admin, user, badge)

      assert {:ok, {loaded, users}} =
               Badges.load_badge_users(admin, "#{badge.id}", @pagination)

      assert loaded.id == badge.id
      assert %Scrivener.Page{} = users
      assert user.id in Enum.map(users.entries, & &1.id)
    end

    test "a plain moderator is unauthorized" do
      badge = badge_fixture()

      assert Badges.load_badge_users(moderator_user_fixture(), "#{badge.id}", @pagination) ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Badges.load_badge_users(admin_user_fixture(), "abc", @pagination) ==
               {:error, :not_found}
    end

    test "an unknown id is not-found" do
      assert Badges.load_badge_users(admin_user_fixture(), "2147483647", @pagination) ==
               {:error, :not_found}
    end
  end
end
