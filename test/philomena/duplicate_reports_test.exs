defmodule Philomena.DuplicateReportsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.DuplicateReports`
  functions: the index/show loaders, the reporter-facing
  `create_duplicate_report/2`, the read-only `image_duplicate_reports/2`, and the
  moderation actions (accept, accept-reverse, claim, unclaim, reject).

  These pin the id parsing, the `:show`/`:edit` authorization on the
  possibly-nil load (including the admin/other-actor divergence), the
  write-access checks on report submission, and the moderation log entries -
  type strings, bodies, and subject paths - that each moderation action writes
  on success.

  The read/moderation actor here is a plain `User.t()` or `nil`, matching what
  the controller hands in as `conn.assigns.current_user`; `create_duplicate_report/2`
  instead takes the `Philomena.Attribution.Actor` struct built by
  `UserAttributionPlug`.
  """

  use Philomena.DataCase, async: true

  alias Philomena.DuplicateReports
  alias Philomena.DuplicateReports.DuplicateReport
  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo

  import Philomena.AttributionFixtures
  import Philomena.DuplicateReportsFixtures
  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

  # A truthy ban value in the shape production passes (the result of
  # Philomena.Bans.find/3); only its presence matters to verify_write_access.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  @pagination %{page_number: 1, page_size: 25}

  defp only_moderation_log! do
    Repo.one!(ModerationLog)
  end

  describe "list_duplicate_reports/2" do
    test "with no states param defaults to the open and claimed reports" do
      open = duplicate_report_fixture(image_fixture(), image_fixture())
      claimed = duplicate_report_fixture(image_fixture(), image_fixture())
      rejected = duplicate_report_fixture(image_fixture(), image_fixture())

      moderator = moderator_user_fixture()
      {:ok, _} = DuplicateReports.claim_duplicate_report(moderator, claimed.id)
      {:ok, _} = DuplicateReports.reject_duplicate_report(moderator, rejected.id)

      page = DuplicateReports.list_duplicate_reports(%{}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert open.id in ids
      assert claimed.id in ids
      refute rejected.id in ids
    end

    test "a blank states value falls back to the open and claimed default" do
      open = duplicate_report_fixture(image_fixture(), image_fixture())

      page = DuplicateReports.list_duplicate_reports(%{"states" => ""}, @pagination)

      assert open.id in Enum.map(page.entries, & &1.id)
    end

    test "an explicit single state filters to that state" do
      open = duplicate_report_fixture(image_fixture(), image_fixture())
      rejected = duplicate_report_fixture(image_fixture(), image_fixture())
      {:ok, _} = DuplicateReports.reject_duplicate_report(moderator_user_fixture(), rejected.id)

      page = DuplicateReports.list_duplicate_reports(%{"states" => "rejected"}, @pagination)
      ids = Enum.map(page.entries, & &1.id)

      assert rejected.id in ids
      refute open.id in ids
    end

    test "a list of states is accepted" do
      open = duplicate_report_fixture(image_fixture(), image_fixture())
      rejected = duplicate_report_fixture(image_fixture(), image_fixture())
      {:ok, _} = DuplicateReports.reject_duplicate_report(moderator_user_fixture(), rejected.id)

      page =
        DuplicateReports.list_duplicate_reports(%{"states" => ["open", "rejected"]}, @pagination)

      ids = Enum.map(page.entries, & &1.id)

      assert open.id in ids
      assert rejected.id in ids
    end

    test "a states selection filtered down to nothing matches no reports" do
      duplicate_report_fixture(image_fixture(), image_fixture())

      page = DuplicateReports.list_duplicate_reports(%{"states" => ["bogus"]}, @pagination)

      assert page.entries == []
    end

    test "a bogus value alongside a valid one keeps only the valid state" do
      open = duplicate_report_fixture(image_fixture(), image_fixture())

      page =
        DuplicateReports.list_duplicate_reports(%{"states" => ["bogus", "open"]}, @pagination)

      assert open.id in Enum.map(page.entries, & &1.id)
    end

    test "reports carry their user, modifier, and both images preloaded" do
      duplicate_report_fixture(image_fixture(), image_fixture())

      page = DuplicateReports.list_duplicate_reports(%{}, @pagination)
      [report | _] = page.entries

      assert Ecto.assoc_loaded?(report.user)
      assert Ecto.assoc_loaded?(report.modifier)
      assert Ecto.assoc_loaded?(report.image)
      assert Ecto.assoc_loaded?(report.duplicate_of_image)
    end
  end

  describe "show_duplicate_report/1" do
    test "loads a report by string id with its images preloaded" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert {:ok, loaded} = DuplicateReports.show_duplicate_report(to_string(report.id))
      assert loaded.id == report.id
      assert Ecto.assoc_loaded?(loaded.image)
      assert Ecto.assoc_loaded?(loaded.duplicate_of_image)
    end

    test "accepts an integer id" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert {:ok, loaded} = DuplicateReports.show_duplicate_report(report.id)
      assert loaded.id == report.id
    end

    test "a non-castable id is not found" do
      assert DuplicateReports.show_duplicate_report("not-a-number") == {:error, :not_found}
    end

    test "a well-formed but unknown id is not found" do
      assert DuplicateReports.show_duplicate_report("2147483647") == {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      assert DuplicateReports.show_duplicate_report("99999999999999999999") ==
               {:error, :not_found}
    end
  end

  describe "create_duplicate_report/2" do
    defp report_params(source, target) do
      %{
        "duplicate_report" => %{
          "image_id" => to_string(source.id),
          "duplicate_of_image_id" => to_string(target.id)
        }
      }
    end

    test "an anonymous actor with a fingerprint submits a report" do
      source = image_fixture()
      target = image_fixture()

      assert {:ok, %DuplicateReport{} = report} =
               DuplicateReports.create_duplicate_report(actor(), report_params(source, target))

      assert report.image_id == source.id
      assert report.duplicate_of_image_id == target.id
    end

    test "a signed-in actor is recorded as the reporter" do
      user = confirmed_user_fixture()
      source = image_fixture()
      target = image_fixture()

      assert {:ok, %DuplicateReport{} = report} =
               DuplicateReports.create_duplicate_report(
                 actor(user),
                 report_params(source, target)
               )

      assert report.user_id == user.id
    end

    test "a banned actor is refused before anything else" do
      source = image_fixture()
      target = image_fixture()

      assert DuplicateReports.create_duplicate_report(
               actor(confirmed_user_fixture(), ban: @ban),
               report_params(source, target)
             ) == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized" do
      source = image_fixture()
      target = image_fixture()

      assert DuplicateReports.create_duplicate_report(
               actor(confirmed_user_fixture(), fingerprint: nil),
               report_params(source, target)
             ) == {:error, :unauthorized}
    end

    test "the ban wins over a missing fingerprint" do
      source = image_fixture()
      target = image_fixture()

      assert DuplicateReports.create_duplicate_report(
               actor(confirmed_user_fixture(), ban: @ban, fingerprint: nil),
               report_params(source, target)
             ) == {:error, :ban}
    end

    test "a missing duplicate_report param is not found" do
      assert DuplicateReports.create_duplicate_report(actor(), %{}) == {:error, :not_found}
    end

    test "a source image_id naming no image is not found" do
      target = image_fixture()

      params = %{
        "duplicate_report" => %{
          "image_id" => "2147483647",
          "duplicate_of_image_id" => to_string(target.id)
        }
      }

      assert DuplicateReports.create_duplicate_report(actor(), params) == {:error, :not_found}
    end

    test "a resolvable source with an unknown target is report_failed, carrying the source" do
      source = image_fixture()

      params = %{
        "duplicate_report" => %{
          "image_id" => to_string(source.id),
          "duplicate_of_image_id" => "2147483647"
        }
      }

      assert {:error, :report_failed, carried} =
               DuplicateReports.create_duplicate_report(actor(), params)

      assert carried.id == source.id
    end

    test "reporting an image as a duplicate of itself is a rejected changeset" do
      image = image_fixture()

      assert {:error, :report_failed, carried} =
               DuplicateReports.create_duplicate_report(actor(), report_params(image, image))

      assert carried.id == image.id
    end
  end

  describe "accept_duplicate_report/2" do
    test "denies an anonymous actor" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.accept_duplicate_report(nil, report.id) == {:error, :unauthorized}
    end

    test "denies a regular user" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.accept_duplicate_report(confirmed_user_fixture(), report.id) ==
               {:error, :unauthorized}
    end

    test "a moderator accepts the report, merges the images, and logs it" do
      moderator = moderator_user_fixture()
      source = image_fixture()
      target = image_fixture()
      report = duplicate_report_fixture(source, target)

      assert {:ok, results} = DuplicateReports.accept_duplicate_report(moderator, report.id)
      assert results.duplicate_report.state == "accepted"

      # The source image is hidden and pointed at the target.
      source = Repo.get!(Image, source.id)
      assert source.hidden_from_users == true
      assert source.duplicate_id == target.id

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "DuplicateReport.Accept:create"
      assert log.subject_path == "/images/#{source.id}"
      assert log.body == "Accepted duplicate report, merged #{source.id} into #{target.id}"
    end

    test "a well-formed unknown id is unauthorized for a moderator, not found for an admin" do
      assert DuplicateReports.accept_duplicate_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert DuplicateReports.accept_duplicate_report(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert DuplicateReports.accept_duplicate_report(moderator_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end
  end

  describe "accept_reverse_duplicate_report/2" do
    test "denies an anonymous actor" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.accept_reverse_duplicate_report(nil, report.id) ==
               {:error, :unauthorized}
    end

    test "denies a regular user" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.accept_reverse_duplicate_report(confirmed_user_fixture(), report.id) ==
               {:error, :unauthorized}
    end

    test "a moderator reverse-accepts, merging the target into the source, and logs it" do
      moderator = moderator_user_fixture()
      source = image_fixture()
      target = image_fixture()
      report = duplicate_report_fixture(source, target)

      assert {:ok, results} =
               DuplicateReports.accept_reverse_duplicate_report(moderator, report.id)

      assert results.duplicate_report.state == "accepted"

      # The reverse merge hides the target image, pointing it at the source.
      target = Repo.get!(Image, target.id)
      assert target.hidden_from_users == true
      assert target.duplicate_id == source.id

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "DuplicateReport.AcceptReverse:create"
      assert log.subject_path == "/images/#{target.id}"

      assert log.body ==
               "Reverse-accepted duplicate report, merged #{target.id} into #{source.id}"
    end

    test "a well-formed unknown id is unauthorized for a moderator, not found for an admin" do
      assert DuplicateReports.accept_reverse_duplicate_report(
               moderator_user_fixture(),
               "2147483647"
             ) == {:error, :unauthorized}

      assert DuplicateReports.accept_reverse_duplicate_report(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert DuplicateReports.accept_reverse_duplicate_report(
               moderator_user_fixture(),
               "not-an-integer"
             ) == {:error, :not_found}
    end
  end

  describe "claim_duplicate_report/2" do
    test "denies an anonymous actor" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.claim_duplicate_report(nil, report.id) == {:error, :unauthorized}
    end

    test "denies a regular user" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.claim_duplicate_report(confirmed_user_fixture(), report.id) ==
               {:error, :unauthorized}
    end

    test "a moderator claims the report and logs it" do
      moderator = moderator_user_fixture()
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert {:ok, claimed} = DuplicateReports.claim_duplicate_report(moderator, report.id)
      assert claimed.state == "claimed"
      assert claimed.modifier_id == moderator.id

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "DuplicateReport.Claim:create"
      assert log.subject_path == "/duplicate_reports"
      assert log.body == "Claimed a duplicate report"
    end

    test "a well-formed unknown id is unauthorized for a moderator, not found for an admin" do
      assert DuplicateReports.claim_duplicate_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert DuplicateReports.claim_duplicate_report(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert DuplicateReports.claim_duplicate_report(moderator_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end
  end

  describe "unclaim_duplicate_report/2" do
    test "denies a regular user" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.unclaim_duplicate_report(confirmed_user_fixture(), report.id) ==
               {:error, :unauthorized}
    end

    test "a moderator releases a claimed report and logs it" do
      moderator = moderator_user_fixture()
      report = duplicate_report_fixture(image_fixture(), image_fixture())
      {:ok, _} = DuplicateReports.claim_duplicate_report(moderator, report.id)

      assert {:ok, released} = DuplicateReports.unclaim_duplicate_report(moderator, report.id)
      assert released.state == "open"
      assert released.modifier_id == nil

      log = Repo.get_by!(ModerationLog, type: "DuplicateReport.Claim:delete")
      assert log.user_id == moderator.id
      assert log.subject_path == "/duplicate_reports"
      assert log.body == "Released a duplicate report"
    end

    test "a well-formed unknown id is unauthorized for a moderator, not found for an admin" do
      assert DuplicateReports.unclaim_duplicate_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert DuplicateReports.unclaim_duplicate_report(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert DuplicateReports.unclaim_duplicate_report(moderator_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end
  end

  describe "reject_duplicate_report/2" do
    test "denies an anonymous actor" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.reject_duplicate_report(nil, report.id) == {:error, :unauthorized}
    end

    test "denies a regular user" do
      report = duplicate_report_fixture(image_fixture(), image_fixture())

      assert DuplicateReports.reject_duplicate_report(confirmed_user_fixture(), report.id) ==
               {:error, :unauthorized}
    end

    test "a moderator rejects the report and logs the image pair" do
      moderator = moderator_user_fixture()
      source = image_fixture()
      target = image_fixture()
      report = duplicate_report_fixture(source, target)

      assert {:ok, rejected} = DuplicateReports.reject_duplicate_report(moderator, report.id)
      assert rejected.state == "rejected"
      assert rejected.modifier_id == moderator.id

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "DuplicateReport.Reject:create"
      assert log.subject_path == "/duplicate_reports"
      assert log.body == "Rejected duplicate report (#{source.id} -> #{target.id})"
    end

    test "a well-formed unknown id is unauthorized for a moderator, not found for an admin" do
      assert DuplicateReports.reject_duplicate_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert DuplicateReports.reject_duplicate_report(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert DuplicateReports.reject_duplicate_report(moderator_user_fixture(), "not-an-integer") ==
               {:error, :not_found}
    end
  end

  describe "image_duplicate_reports/2" do
    test "an anonymous actor lists reports with the image on either side" do
      image = image_fixture()
      other_source = image_fixture()
      other_target = image_fixture()

      # One report where the image is the reported source, one where it is the
      # claimed duplicate target.
      as_source = duplicate_report_fixture(image, other_target)
      as_target = duplicate_report_fixture(other_source, image)

      assert {:ok, {loaded, reports}} =
               DuplicateReports.image_duplicate_reports(nil, to_string(image.id))

      assert loaded.id == image.id
      assert Enum.sort(Enum.map(reports, & &1.id)) == Enum.sort([as_source.id, as_target.id])
    end

    test "a regular user lists reports on a visible image" do
      user = confirmed_user_fixture()
      image = image_fixture()
      other = image_fixture()
      report = duplicate_report_fixture(image, other)

      assert {:ok, {loaded, reports}} =
               DuplicateReports.image_duplicate_reports(user, to_string(image.id))

      assert loaded.id == image.id
      assert Enum.map(reports, & &1.id) == [report.id]
    end

    test "each report preloads its user and modifier" do
      reporter = confirmed_user_fixture()
      image = image_fixture()
      other = image_fixture()
      duplicate_report_fixture(image, other, reporter)

      assert {:ok, {_image, [report]}} =
               DuplicateReports.image_duplicate_reports(nil, to_string(image.id))

      assert Ecto.assoc_loaded?(report.user)
      assert Ecto.assoc_loaded?(report.modifier)
      assert report.user.id == reporter.id
    end

    test "an image with no reports yields an empty list" do
      image = image_fixture()

      assert {:ok, {loaded, reports}} =
               DuplicateReports.image_duplicate_reports(nil, to_string(image.id))

      assert loaded.id == image.id
      assert reports == []
    end

    test "accepts an integer id" do
      image = image_fixture()
      other = image_fixture()
      report = duplicate_report_fixture(image, other)

      assert {:ok, {_image, reports}} = DuplicateReports.image_duplicate_reports(nil, image.id)
      assert Enum.map(reports, & &1.id) == [report.id]
    end

    test "a hidden image is unauthorized for a regular user" do
      user = confirmed_user_fixture()
      image = image_fixture(hidden_from_users: true)

      assert DuplicateReports.image_duplicate_reports(user, to_string(image.id)) ==
               {:error, :unauthorized}
    end

    test "a hidden image is unauthorized for an anonymous actor" do
      image = image_fixture(hidden_from_users: true)

      assert DuplicateReports.image_duplicate_reports(nil, to_string(image.id)) ==
               {:error, :unauthorized}
    end

    test "a hidden image is listable by a moderator" do
      moderator = moderator_user_fixture()
      image = image_fixture(hidden_from_users: true)
      other = image_fixture()
      report = duplicate_report_fixture(image, other)

      assert {:ok, {loaded, reports}} =
               DuplicateReports.image_duplicate_reports(moderator, to_string(image.id))

      assert loaded.id == image.id
      assert Enum.map(reports, & &1.id) == [report.id]
    end

    test "an unknown well-formed id is unauthorized for an anonymous actor" do
      # The image loads as nil and a nil actor fails :show on the nil load, so the
      # missing image surfaces as unauthorized rather than not found.
      assert DuplicateReports.image_duplicate_reports(nil, "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a regular user" do
      assert DuplicateReports.image_duplicate_reports(confirmed_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator" do
      assert DuplicateReports.image_duplicate_reports(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}
    end

    test "an unknown well-formed id is not found for an admin" do
      # An admin clears :show on the nil load via the blanket ability rule, then
      # the image presence check fails, so the missing image is not found.
      assert DuplicateReports.image_duplicate_reports(admin_user_fixture(), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      assert DuplicateReports.image_duplicate_reports(nil, "not-a-number") ==
               {:error, :not_found}
    end

    test "an out-of-range id is not found" do
      # IntegerId.parse rejects a value the integer column could not hold before
      # the row is ever queried, ahead of any authorization.
      assert DuplicateReports.image_duplicate_reports(nil, "99999999999999999999") ==
               {:error, :not_found}
    end
  end
end
