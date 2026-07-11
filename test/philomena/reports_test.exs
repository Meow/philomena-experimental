defmodule Philomena.ReportsTest do
  @moduledoc """
  Context-level tests for the actor-first `Philomena.Reports.create_report/4`.

  These pin the attribution carried onto the inserted report, the open-report
  limit (regular users and anonymous IPs capped at `max_open_reports/0`, staff
  exempt), and the rejected-changeset shape. No moderation log is written.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures
  import Philomena.ImagesFixtures
  import Philomena.ReportsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Reports
  alias Philomena.Reports.Report
  alias Philomena.Repo

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to the write-access and
  # not-banned checks the loaders run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  # Report params in the shape the submission form posts: a reason, a user
  # agent, and a non-internal rule the report cites.
  defp report_params(attrs \\ %{}) do
    attrs
    |> Enum.into(%{
      "reason" => "Test report reason",
      "user_agent" => "Test Browser/1.0"
    })
    |> Map.put_new_lazy("rule_id", fn -> Philomena.RulesFixtures.rule_fixture().id end)
  end

  defp no_moderation_logs! do
    assert Repo.aggregate(ModerationLog, :count) == 0
  end

  describe "max_open_reports/0" do
    test "is five" do
      assert Reports.max_open_reports() == 5
    end
  end

  describe "create_report/4" do
    setup do
      %{image: image_fixture()}
    end

    test "a signed-in actor creates a report attributed to the user", %{image: image} do
      user = confirmed_user_fixture()

      assert {:ok, %Report{} = report} =
               Reports.create_report(actor(user), "Image", image.id, report_params())

      assert report.user_id == user.id
      assert report.reportable_type == "Image"
      assert report.reportable_id == image.id
      assert report.reason == "Test report reason"
      assert report.open
      no_moderation_logs!()
    end

    test "an anonymous fingerprinted actor creates a report with no user", %{image: image} do
      assert {:ok, %Report{} = report} =
               Reports.create_report(actor(nil), "Image", image.id, report_params())

      assert report.user_id == nil
      assert report.ip != nil
      assert report.open
      no_moderation_logs!()
    end

    test "a blank reason is a rejected changeset", %{image: image} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Reports.create_report(
                 actor(confirmed_user_fixture()),
                 "Image",
                 image.id,
                 report_params(%{"reason" => ""})
               )

      refute changeset.valid?
      assert changeset.errors[:reason]
    end

    test "a regular user holding the maximum open reports is refused", %{image: image} do
      user = confirmed_user_fixture()

      # Seed the user up to the limit; the next submission is refused.
      for _ <- 1..Reports.max_open_reports() do
        report_fixture({"Image", image.id}, user)
      end

      assert Reports.create_report(actor(user), "Image", image.id, report_params()) ==
               {:error, :too_many_reports}
    end

    test "a moderator is exempt from the open-report limit", %{image: image} do
      moderator = moderator_user_fixture()

      # The same open-report count that refuses a regular user does not refuse
      # staff, whose role is never rate-limited.
      for _ <- 1..Reports.max_open_reports() do
        report_fixture({"Image", image.id}, moderator)
      end

      assert {:ok, %Report{}} =
               Reports.create_report(actor(moderator), "Image", image.id, report_params())
    end

    test "the limit is keyed by IP for an anonymous actor", %{image: image} do
      # Anonymous submissions carry no user, so the cap is enforced against the
      # actor's IP, which the anonymous attribution fixture shares.
      for _ <- 1..Reports.max_open_reports() do
        report_fixture({"Image", image.id})
      end

      assert Reports.create_report(actor(nil), "Image", image.id, report_params()) ==
               {:error, :too_many_reports}
    end
  end

  describe "load_image_for_report/2" do
    # Backs the report form (a GET-guarded action), so it runs the not-banned
    # check first (no fingerprint requirement) and then loads and authorizes the
    # image for :show.

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      # verify_not_banned runs before the loader, so a banned actor is
      # {:error, :ban} even against an id that could never load.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_image_for_report(actor, "abc") == {:error, :ban}
    end

    test "an anonymous actor loads the report form for a visible image", %{image: image} do
      assert {:ok, {%Image{} = loaded, %Ecto.Changeset{} = changeset}} =
               Reports.load_image_for_report(actor(nil), "#{image.id}")

      assert loaded.id == image.id

      # The image carries the preloads the form renders.
      assert is_list(loaded.sources)
      assert is_list(loaded.tags)

      # The changeset is over a Report addressed at this image.
      assert %Report{} = changeset.data
      assert changeset.data.reportable_type == "Image"
      assert changeset.data.reportable_id == image.id
    end

    test "a regular user loads the report form for a visible image", %{image: image} do
      assert {:ok, {%Image{} = loaded, %Ecto.Changeset{}}} =
               Reports.load_image_for_report(actor(confirmed_user_fixture()), "#{image.id}")

      assert loaded.id == image.id
    end

    test "a regular user cannot load a hidden image's report form" do
      image = image_fixture(%{hidden_from_users: true})

      assert Reports.load_image_for_report(actor(confirmed_user_fixture()), "#{image.id}") ==
               {:error, :unauthorized}
    end

    # A well-formed id naming no row loads nil, which no :show rule permits; the
    # loader returns unauthorized rather than not-found.
    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Reports.load_image_for_report(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}
    end

    test "an id that cannot name a row is not found" do
      assert Reports.load_image_for_report(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end
  end

  describe "load_image_for_report_creation/2" do
    # Backs the report submission (a write), so it runs the write-access check
    # first (ban -> :ban, missing fingerprint -> :unauthorized) and then the same
    # image load-and-authorize chain as the report form.

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_image_for_report_creation(actor, "abc") == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading, signed in or not" do
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert Reports.load_image_for_report_creation(signed_in, "abc") == {:error, :unauthorized}
      assert Reports.load_image_for_report_creation(anonymous, "abc") == {:error, :unauthorized}
    end

    test "a valid anonymous fingerprinted actor loads a visible image", %{image: image} do
      # actor(nil) carries the shared fingerprint, so it clears the write-access
      # check and reaches the image load.
      assert {:ok, %Image{} = loaded} =
               Reports.load_image_for_report_creation(actor(nil), "#{image.id}")

      assert loaded.id == image.id
      assert is_list(loaded.sources)
      assert is_list(loaded.tags)
    end

    test "a regular user cannot load a hidden image" do
      image = image_fixture(%{hidden_from_users: true})

      assert Reports.load_image_for_report_creation(
               actor(confirmed_user_fixture()),
               "#{image.id}"
             ) ==
               {:error, :unauthorized}
    end

    test "a well-formed id naming no row is unauthorized, not not-found" do
      assert Reports.load_image_for_report_creation(actor(confirmed_user_fixture()), "999999999") ==
               {:error, :unauthorized}
    end

    test "an id that cannot name a row is not found" do
      assert Reports.load_image_for_report_creation(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end
  end
end
