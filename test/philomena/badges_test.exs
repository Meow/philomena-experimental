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
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo

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
end
