defmodule Philomena.DuplicateReportsTest do
  @moduledoc """
  Context-level tests for the actor-first read API on
  `Philomena.DuplicateReports`: `image_duplicate_reports/2`.

  These pin the id parsing, the `:show` authorization on the possibly-nil image
  load (including the hidden-image and admin/other-actor divergences), and the
  bidirectional report lookup on success.

  The actor here is a plain `User.t()` or `nil`, matching what the controller
  hands in as `conn.assigns.current_user`.
  """

  use Philomena.DataCase, async: true

  alias Philomena.DuplicateReports

  import Philomena.DuplicateReportsFixtures
  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

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
