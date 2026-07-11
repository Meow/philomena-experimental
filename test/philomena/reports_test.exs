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

  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Reports
  alias Philomena.Reports.Report
  alias Philomena.Repo

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
end
