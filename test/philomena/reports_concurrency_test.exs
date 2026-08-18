defmodule Philomena.ReportsConcurrencyTest do
  use Philomena.ConcurrentDataCase

  @moduletag :search

  import Philomena.AttributionFixtures, only: [actor: 1]
  import Philomena.ImagesFixtures
  import Philomena.ReportsFixtures
  import Philomena.UsersFixtures

  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo
  alias Philomena.Reports
  alias Philomena.Reports.Report
  alias PhilomenaQuery.Search

  setup do
    Search.clear_index!(Report)
    %{report: report_fixture(image_id: image_fixture().id)}
  end

  test "a second or racing claim cannot reassign the report", %{report: report} do
    results =
      concurrently(
        for moderator <- [moderator_user_fixture(), moderator_user_fixture()] do
          fn -> Reports.claim_report(actor(moderator), report.id) end
        end
      )

    assert Enum.count(results, &match?({:ok, %Report{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1
    assert Repo.aggregate(ModerationLog, :count) == 1
  end
end
