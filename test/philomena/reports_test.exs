defmodule Philomena.ReportsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.Reports` functions:
  the actor-first `create_report/4`, the report form/submission loaders, the
  admin report listing (`load_report_index/3`) and single-report load
  (`load_report/2`), the claim/unclaim/close moderation actions, and the
  mod-note staff gate.

  These pin the attribution carried onto the inserted report, the open-report
  limit (regular users and anonymous IPs capped at `max_open_reports/0`, staff
  exempt), the rejected-changeset shape, the `:index`/`:show`/`:edit`
  authorization matrices (including uniform not-found results for absent IDs),
  the `ReportPage` struct shape and its
  `rq`-search vs default branches, and the mod-note staff gate.

  `load_report_index/3` reads through OpenSearch, so this module follows the
  search rules: async: false, with the Report index cycled in setup.
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.AttributionFixtures
  import Philomena.CommissionsFixtures
  import Philomena.ConversationsFixtures
  import Philomena.GalleriesFixtures
  import Philomena.ImagesFixtures
  import Philomena.ModNotesFixtures
  import Philomena.ReportsFixtures
  import Philomena.UsersFixtures
  import Philomena.RulesFixtures

  alias Philomena.Commissions.Commission
  alias Philomena.Conversations.Conversation
  alias Philomena.Galleries.Gallery
  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Reports
  alias Philomena.Reports.Report
  alias Philomena.Reports.ReportPage
  alias Philomena.Reports.SearchIndex
  alias Philomena.Repo
  alias Philomena.Users.User
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  @pagination %{page_number: 1, page_size: 25}

  setup do
    Search.clear_index!(Report)
    :ok
  end

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
               Reports.create_report(actor(user), report_params(), image_id: image.id)

      assert report.user_id == user.id
      assert report.image_id == image.id
      assert report.reason == "Test report reason"
      assert report.open
      no_moderation_logs!()
    end

    test "an anonymous fingerprinted actor creates a report with no user", %{image: image} do
      assert {:ok, %Report{} = report} =
               Reports.create_report(actor(nil), report_params(), image_id: image.id)

      assert report.user_id == nil
      assert report.ip != nil
      assert report.open
      no_moderation_logs!()
    end

    test "a blank reason is a rejected changeset", %{image: image} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Reports.create_report(
                 actor(confirmed_user_fixture()),
                 report_params(%{"reason" => ""}),
                 image_id: image.id
               )

      refute changeset.valid?
      assert changeset.errors[:reason]
    end

    test "a regular user holding the maximum open reports is refused", %{image: image} do
      user = confirmed_user_fixture()

      # Seed the user up to the limit; the next submission is refused.
      for _ <- 1..Reports.max_open_reports() do
        report_fixture(user, image_id: image.id)
      end

      assert Reports.create_report(actor(user), report_params(), image_id: image.id) ==
               {:error, :too_many_reports}
    end

    test "a moderator is exempt from the open-report limit", %{image: image} do
      moderator = moderator_user_fixture()

      # The same open-report count that refuses a regular user does not refuse
      # staff, whose role is never rate-limited.
      for _ <- 1..Reports.max_open_reports() do
        report_fixture(moderator, image_id: image.id)
      end

      assert {:ok, %Report{}} =
               Reports.create_report(actor(moderator), report_params(), image_id: image.id)
    end

    test "the limit is keyed by IP for an anonymous actor", %{image: image} do
      # Anonymous submissions carry no user, so the cap is enforced against the
      # actor's IP, which the anonymous attribution fixture shares.
      for _ <- 1..Reports.max_open_reports() do
        report_fixture(image_id: image.id)
      end

      assert Reports.create_report(actor(nil), report_params(), image_id: image.id) ==
               {:error, :too_many_reports}
    end
  end

  describe "load_report_index/3" do
    test "an anonymous viewer is unauthorized" do
      assert Reports.load_report_index(actor(), %{}, @pagination) == {:error, :unauthorized}
    end

    test "a regular user is unauthorized" do
      assert Reports.load_report_index(actor(confirmed_user_fixture()), %{}, @pagination) ==
               {:error, :unauthorized}
    end

    test "a moderator is authorized" do
      assert {:ok, %ReportPage{}} =
               Reports.load_report_index(actor(moderator_user_fixture()), %{}, @pagination)
    end

    test "an admin gets the assembled page struct with the searched report" do
      admin = admin_user_fixture()
      image = image_fixture()
      report = report_fixture(image_id: image.id)
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{reports: reports, my_reports: my, system_reports: system}} =
               Reports.load_report_index(actor(admin), %{}, @pagination)

      assert %Scrivener.Page{} = reports
      assert is_list(my)
      assert is_list(system)

      # The open, non-own, non-system report is in the default searched list.
      assert report.id in Enum.map(reports.entries, & &1.id)
    end

    test "the default view returns empty lists on an empty table" do
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{reports: reports, my_reports: [], system_reports: []}} =
               Reports.load_report_index(actor(admin_user_fixture()), %{}, @pagination)

      assert Enum.empty?(reports.entries)
    end

    test "the actor's own open reports populate my_reports and leave the searched list" do
      admin = admin_user_fixture()
      image = image_fixture()
      report = report_fixture(image_id: image.id)
      {:ok, _} = Reports.claim_report(actor(admin), to_string(report.id))
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{my_reports: my, reports: reports}} =
               Reports.load_report_index(actor(admin), %{}, @pagination)

      assert report.id in Enum.map(my, & &1.id)
      refute report.id in Enum.map(reports.entries, & &1.id)
    end

    test "open system reports populate system_reports" do
      admin = admin_user_fixture()
      image = image_fixture()
      rule = Philomena.RulesFixtures.rule_fixture()

      {:ok, report} =
        Reports.create_system_report(rule.name, "System reason", image_id: image.id)

      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{system_reports: system, reports: reports}} =
               Reports.load_report_index(actor(admin), %{}, @pagination)

      assert report.id in Enum.map(system, & &1.id)

      # The system report is excluded from the default searched list.
      refute report.id in Enum.map(reports.entries, & &1.id)
    end

    test "the rq search branch drives reports and empties the own and system lists" do
      admin = admin_user_fixture()
      image = image_fixture()
      report = report_fixture(image_id: image.id)

      # A report that would land in my_reports in the default view.
      {:ok, _} = Reports.claim_report(actor(admin), to_string(report.id))
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{reports: reports, my_reports: [], system_reports: []}} =
               Reports.load_report_index(actor(admin), %{"rq" => "*"}, @pagination)

      assert report.id in Enum.map(reports.entries, & &1.id)
    end

    test "a malformed rq raises MatchError" do
      # An authorized actor reaches the query compile, which returns an error
      # tuple that the {:ok, query} match rejects.
      assert_raise MatchError, fn ->
        Reports.load_report_index(actor(admin_user_fixture()), %{"rq" => "("}, @pagination)
      end
    end
  end

  describe "load_report/2" do
    setup do
      image = image_fixture()
      %{image: image, report: report_fixture(image_id: image.id)}
    end

    test "a moderator loads a report with the reportable resolved", %{
      image: image,
      report: report
    } do
      assert {:ok, loaded} =
               Reports.load_report(actor(moderator_user_fixture()), to_string(report.id))

      assert loaded.id == report.id
      assert loaded.image.id == image.id
    end

    test "an admin loads a report", %{report: report} do
      assert {:ok, loaded} =
               Reports.load_report(actor(admin_user_fixture()), to_string(report.id))

      assert loaded.id == report.id
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.load_report(actor(confirmed_user_fixture()), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized", %{report: report} do
      assert Reports.load_report(actor(), to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert Reports.load_report(actor(moderator_user_fixture()), "2147483647") ==
               {:error, :unauthorized}

      assert Reports.load_report(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.load_report(actor(admin_user_fixture()), "not-a-number") ==
               {:error, :not_found}
    end
  end

  describe "claim_report/2" do
    setup do
      image = image_fixture()
      %{report: report_fixture(image_id: image.id)}
    end

    test "a moderator claims a report", %{report: report} do
      moderator = moderator_user_fixture()

      assert {:ok, claimed} = Reports.claim_report(actor(moderator), to_string(report.id))
      assert claimed.admin_id == moderator.id
      assert claimed.state == "in_progress"
      assert claimed.open
    end

    test "claiming an already-claimed report reassigns it to the new claimant", %{report: report} do
      # NOTE: the claim changeset's validate_inclusion(:admin_id, []) runs before
      # the admin_id is put, so it never guards an already-claimed report; a
      # second claim succeeds and reassigns the admin.
      first = moderator_user_fixture()
      second = moderator_user_fixture()

      {:ok, claimed} = Reports.claim_report(actor(first), to_string(report.id))
      assert claimed.admin_id == first.id

      assert {:ok, reclaimed} = Reports.claim_report(actor(second), to_string(report.id))
      assert reclaimed.admin_id == second.id
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.claim_report(actor(confirmed_user_fixture()), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized", %{report: report} do
      assert Reports.claim_report(actor(), to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not-found for every actor" do
      assert Reports.claim_report(actor(moderator_user_fixture()), "2147483647") ==
               {:error, :not_found}

      assert Reports.claim_report(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.claim_report(actor(admin_user_fixture()), "not-a-number") ==
               {:error, :not_found}
    end
  end

  describe "unclaim_report/2" do
    setup do
      image = image_fixture()
      report = report_fixture(image_id: image.id)
      {:ok, _} = Reports.claim_report(actor(admin_user_fixture()), to_string(report.id))
      %{report: report}
    end

    test "a moderator unclaims a report", %{report: report} do
      assert {:ok, unclaimed} =
               Reports.unclaim_report(actor(moderator_user_fixture()), to_string(report.id))

      assert unclaimed.admin_id == nil
      assert unclaimed.state == "open"
      assert unclaimed.open
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.unclaim_report(actor(confirmed_user_fixture()), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized", %{report: report} do
      assert Reports.unclaim_report(actor(), to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not-found for every actor" do
      assert Reports.unclaim_report(actor(moderator_user_fixture()), "2147483647") ==
               {:error, :not_found}

      assert Reports.unclaim_report(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.unclaim_report(actor(admin_user_fixture()), "not-a-number") ==
               {:error, :not_found}
    end
  end

  describe "close_report/2" do
    setup do
      image = image_fixture()
      %{report: report_fixture(image_id: image.id)}
    end

    test "a moderator closes a report", %{report: report} do
      moderator = moderator_user_fixture()

      assert {:ok, closed} = Reports.close_report(actor(moderator), to_string(report.id))
      assert closed.admin_id == moderator.id
      assert closed.state == "closed"
      refute closed.open
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.close_report(actor(confirmed_user_fixture()), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized", %{report: report} do
      assert Reports.close_report(actor(), to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is not-found for every actor" do
      assert Reports.close_report(actor(moderator_user_fixture()), "2147483647") ==
               {:error, :not_found}

      assert Reports.close_report(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.close_report(actor(admin_user_fixture()), "not-a-number") ==
               {:error, :not_found}
    end
  end

  describe "mod_notes/3" do
    setup do
      image = image_fixture()
      report = report_fixture(image_id: image.id)

      note =
        mod_note_fixture_for(moderator_user_fixture(), %{"report_id" => report.id})

      %{report: report, note: note}
    end

    test "a moderator gets the rendered mod notes for the report", %{report: report, note: note} do
      # The renderer zips each note with its rendered body into a {note, body}
      # tuple, so the identity renderer pairs each note with itself.
      notes = Reports.mod_notes(actor(moderator_user_fixture()), report, & &1)
      assert is_list(notes)
      assert note.id in Enum.map(notes, fn {loaded, _body} -> loaded.id end)
    end

    test "a regular user gets nil", %{report: report} do
      assert Reports.mod_notes(actor(confirmed_user_fixture()), report, & &1) == nil
    end

    test "an anonymous viewer gets nil", %{report: report} do
      assert Reports.mod_notes(actor(), report, & &1) == nil
    end
  end

  describe "load_image_for_report/2" do
    # Backs a report write form, so it runs the global write prerequisite before
    # loading and authorizing the image.

    setup do
      %{image: image_fixture()}
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_image_for_report(actor, "abc") == {:error, :ban}
    end

    test "an actor without a fingerprint is rejected before loading" do
      assert Reports.load_image_for_report(actor(nil, fingerprint: nil), "abc") ==
               {:error, :unauthorized}
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
      assert changeset.data.image_id == image.id
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

  describe "load_gallery_for_report/2" do
    # Backs a report write form, so it runs the global write prerequisite before
    # loading and authorizing the gallery.

    setup do
      %{gallery: gallery_fixture(confirmed_user_fixture())}
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_gallery_for_report(actor, "abc") == {:error, :ban}
    end

    test "an actor without a fingerprint is rejected before loading" do
      assert Reports.load_gallery_for_report(actor(nil, fingerprint: nil), "abc") ==
               {:error, :unauthorized}
    end

    test "an anonymous actor loads the report form for a gallery", %{gallery: gallery} do
      assert {:ok, {%Gallery{} = loaded, %Ecto.Changeset{} = changeset}} =
               Reports.load_gallery_for_report(actor(nil), "#{gallery.id}")

      assert loaded.id == gallery.id

      # The changeset is over a Report addressed at this gallery.
      assert %Report{} = changeset.data
      assert changeset.data.gallery_id == gallery.id
    end

    test "a well-formed id naming no row is not-found for every actor" do
      assert Reports.load_gallery_for_report(actor(nil), "999999999") == {:error, :not_found}

      assert Reports.load_gallery_for_report(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end

    test "an id that cannot name a row is not found" do
      assert Reports.load_gallery_for_report(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end
  end

  describe "load_gallery_for_report_creation/2" do
    # Backs the report submission (a write): the write-access check runs first
    # (ban -> :ban, missing fingerprint -> :unauthorized), then the same gallery
    # load-and-authorize chain as the report form.

    setup do
      %{gallery: gallery_fixture(confirmed_user_fixture())}
    end

    test "a banned actor is rejected even while carrying a fingerprint" do
      # The ban is decided before the fingerprint requirement, so a banned actor
      # with a fingerprint is still {:error, :ban}.
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_gallery_for_report_creation(actor, "abc") == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading, signed in or not" do
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert Reports.load_gallery_for_report_creation(signed_in, "abc") == {:error, :unauthorized}
      assert Reports.load_gallery_for_report_creation(anonymous, "abc") == {:error, :unauthorized}
    end

    test "a valid anonymous fingerprinted actor loads a gallery", %{gallery: gallery} do
      assert {:ok, %Gallery{} = loaded} =
               Reports.load_gallery_for_report_creation(actor(nil), "#{gallery.id}")

      assert loaded.id == gallery.id
    end

    test "a well-formed id naming no row is not-found for every actor" do
      assert Reports.load_gallery_for_report_creation(actor(nil), "999999999") ==
               {:error, :not_found}

      assert Reports.load_gallery_for_report_creation(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end

    test "an id that cannot name a row is not found" do
      assert Reports.load_gallery_for_report_creation(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end
  end

  describe "load_user_for_report/2" do
    # Backs a report write form, so it runs the global write prerequisite before
    # loading and authorizing the user.

    setup do
      %{reported: confirmed_user_fixture()}
    end

    test "a banned actor is rejected before any loading, even with a garbage slug" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_user_for_report(actor, "no-such-user") == {:error, :ban}
    end

    test "an actor without a fingerprint is rejected before loading" do
      assert Reports.load_user_for_report(actor(nil, fingerprint: nil), "no-such-user") ==
               {:error, :unauthorized}
    end

    test "an anonymous actor loads the report form for a user", %{reported: reported} do
      assert {:ok, {%User{} = loaded, %Ecto.Changeset{} = changeset}} =
               Reports.load_user_for_report(actor(nil), reported.slug)

      assert loaded.id == reported.id

      # The changeset is over a Report addressed at this user.
      assert %Report{} = changeset.data
      assert changeset.data.reported_user_id == reported.id
    end

    # An unknown slug authorizes nil; no ordinary rule permits it, so an
    # anonymous actor is unauthorized, while an admin sees not-found.
    test "an unknown slug is unauthorized for anonymous, not-found for admin" do
      assert Reports.load_user_for_report(actor(nil), "no-such-user") == {:error, :unauthorized}

      assert Reports.load_user_for_report(actor(admin_user_fixture()), "no-such-user") ==
               {:error, :not_found}
    end
  end

  describe "load_user_for_report_creation/2" do
    # Backs the profile report submission (a write): the write-access check runs
    # first, then the same user lookup and authorization as the report form.

    setup do
      %{reported: confirmed_user_fixture()}
    end

    test "a banned actor is rejected even while carrying a fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_user_for_report_creation(actor, "no-such-user") == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading, signed in or not" do
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert Reports.load_user_for_report_creation(signed_in, "no-such-user") ==
               {:error, :unauthorized}

      assert Reports.load_user_for_report_creation(anonymous, "no-such-user") ==
               {:error, :unauthorized}
    end

    test "a valid anonymous fingerprinted actor loads a user", %{reported: reported} do
      assert {:ok, %User{} = loaded} =
               Reports.load_user_for_report_creation(actor(nil), reported.slug)

      assert loaded.id == reported.id
    end

    test "an unknown slug is unauthorized for anonymous, not-found for admin" do
      assert Reports.load_user_for_report_creation(actor(nil), "no-such-user") ==
               {:error, :unauthorized}

      assert Reports.load_user_for_report_creation(actor(admin_user_fixture()), "no-such-user") ==
               {:error, :not_found}
    end
  end

  describe "load_commission_for_report/2" do
    # Backs a report write form, so it runs the global write prerequisite before
    # loading the user and commission.

    setup do
      user = confirmed_user_fixture()
      commission = commission_fixture(user)
      commission_item_fixture(commission)
      %{user: user, commission: commission}
    end

    test "a banned actor is rejected before any loading, even with a garbage slug" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_commission_for_report(actor, "no-such-user") == {:error, :ban}
    end

    test "an actor without a fingerprint is rejected before loading" do
      assert Reports.load_commission_for_report(actor(nil, fingerprint: nil), "no-such-user") ==
               {:error, :unauthorized}
    end

    test "an anonymous actor loads the report form for a commission", %{
      user: user,
      commission: commission
    } do
      assert {:ok, {%User{} = loaded_user, %Commission{} = loaded, %Ecto.Changeset{} = changeset}} =
               Reports.load_commission_for_report(actor(nil), user.slug)

      assert loaded_user.id == user.id
      assert loaded.id == commission.id

      # The commission carries the preloads its report page renders.
      assert is_list(loaded.items)

      # The changeset is over a Report addressed at this commission.
      assert %Report{} = changeset.data
      assert changeset.data.commission_id == commission.id
    end

    # The lookup runs no authorization, so an unknown slug is not-found for every
    # actor, anonymous or admin alike.
    test "an unknown slug is not found for anonymous and for admin" do
      assert Reports.load_commission_for_report(actor(nil), "no-such-user") ==
               {:error, :not_found}

      assert Reports.load_commission_for_report(actor(admin_user_fixture()), "no-such-user") ==
               {:error, :not_found}
    end

    test "a known user without a commission is not found" do
      user = confirmed_user_fixture()

      assert Reports.load_commission_for_report(actor(nil), user.slug) == {:error, :not_found}
    end
  end

  describe "load_commission_for_report_creation/2" do
    # Backs the commission report submission (a write): the write-access check
    # runs first, then the same user and commission lookup as the report form.

    setup do
      user = confirmed_user_fixture()
      commission = commission_fixture(user)
      commission_item_fixture(commission)
      %{user: user, commission: commission}
    end

    test "a banned actor is rejected even while carrying a fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_commission_for_report_creation(actor, "no-such-user") == {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading, signed in or not" do
      signed_in = actor(confirmed_user_fixture(), fingerprint: nil)
      anonymous = actor(nil, fingerprint: nil)

      assert Reports.load_commission_for_report_creation(signed_in, "no-such-user") ==
               {:error, :unauthorized}

      assert Reports.load_commission_for_report_creation(anonymous, "no-such-user") ==
               {:error, :unauthorized}
    end

    test "a valid anonymous fingerprinted actor loads a user and commission", %{
      user: user,
      commission: commission
    } do
      assert {:ok, {%User{} = loaded_user, %Commission{} = loaded}} =
               Reports.load_commission_for_report_creation(actor(nil), user.slug)

      assert loaded_user.id == user.id
      assert loaded.id == commission.id
      assert is_list(loaded.items)
    end

    test "an unknown slug and a user without a commission are both not found" do
      user = confirmed_user_fixture()

      assert Reports.load_commission_for_report_creation(actor(nil), "no-such-user") ==
               {:error, :not_found}

      assert Reports.load_commission_for_report_creation(actor(nil), user.slug) ==
               {:error, :not_found}
    end
  end

  describe "load_conversation_for_report/2" do
    # Backs a report write form, so it runs the global write prerequisite before
    # loading and authorizing the conversation.

    setup do
      from = confirmed_user_fixture()
      to = confirmed_user_fixture()
      %{conversation: conversation_fixture(from, to), from: from, to: to}
    end

    test "a banned actor is rejected before any loading, even with a garbage slug" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_conversation_for_report(actor, "no-such-slug") == {:error, :ban}
    end

    test "an actor without a fingerprint is rejected before loading" do
      assert Reports.load_conversation_for_report(actor(nil, fingerprint: nil), "no-such-slug") ==
               {:error, :unauthorized}
    end

    test "a participant loads the report form for their conversation", %{
      conversation: conversation,
      to: to
    } do
      assert {:ok, {%Conversation{} = loaded, %Ecto.Changeset{} = changeset}} =
               Reports.load_conversation_for_report(actor(to), conversation.slug)

      assert loaded.id == conversation.id

      # The changeset is over a Report addressed at this conversation.
      assert %Report{} = changeset.data
      assert changeset.data.conversation_id == conversation.id
    end

    test "a non-participant regular user is unauthorized", %{conversation: conversation} do
      assert Reports.load_conversation_for_report(
               actor(confirmed_user_fixture()),
               conversation.slug
             ) == {:error, :unauthorized}
    end

    # An unknown slug authorizes nil; no ordinary rule permits it, so a
    # non-participant is unauthorized, while an admin sees not-found.
    test "an unknown slug is unauthorized for a user, not-found for an admin" do
      assert Reports.load_conversation_for_report(actor(confirmed_user_fixture()), "no-such-slug") ==
               {:error, :unauthorized}

      assert Reports.load_conversation_for_report(actor(admin_user_fixture()), "no-such-slug") ==
               {:error, :not_found}
    end
  end

  describe "load_conversation_for_report_creation/2" do
    # Backs the conversation report submission (a write): the write-access check
    # runs first, then the same conversation load-and-authorize chain as the
    # report form.

    setup do
      from = confirmed_user_fixture()
      to = confirmed_user_fixture()
      %{conversation: conversation_fixture(from, to), from: from, to: to}
    end

    test "a banned actor is rejected even while carrying a fingerprint" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_conversation_for_report_creation(actor, "no-such-slug") ==
               {:error, :ban}
    end

    test "an actor with no fingerprint is unauthorized before any loading", %{
      conversation: conversation
    } do
      actor = actor(confirmed_user_fixture(), fingerprint: nil)

      assert Reports.load_conversation_for_report_creation(actor, conversation.slug) ==
               {:error, :unauthorized}
    end

    test "a participant loads their conversation", %{conversation: conversation, to: to} do
      assert {:ok, %Conversation{} = loaded} =
               Reports.load_conversation_for_report_creation(actor(to), conversation.slug)

      assert loaded.id == conversation.id
    end

    test "a non-participant regular user is unauthorized", %{conversation: conversation} do
      assert Reports.load_conversation_for_report_creation(
               actor(confirmed_user_fixture()),
               conversation.slug
             ) == {:error, :unauthorized}
    end

    test "an unknown slug is unauthorized for a user, not-found for an admin" do
      assert Reports.load_conversation_for_report_creation(
               actor(confirmed_user_fixture()),
               "no-such-slug"
             ) == {:error, :unauthorized}

      assert Reports.load_conversation_for_report_creation(
               actor(admin_user_fixture()),
               "no-such-slug"
             ) == {:error, :not_found}
    end
  end

  describe "Report.target_columns/0" do
    test "target_columns lists all seven columns" do
      assert Report.target_columns() == [
               :image_id,
               :comment_id,
               :post_id,
               :reported_user_id,
               :commission_id,
               :conversation_id,
               :gallery_id
             ]
    end
  end

  describe "create_report/3 single-target acceptance" do
    test "accepts an image report and sets image_id" do
      image = image_fixture()
      report = report_fixture(image_id: image.id)

      assert report.image_id == image.id
    end

    test "accepts a user report and sets reported_user_id" do
      target = confirmed_user_fixture()
      report = report_fixture(reported_user_id: target.id)

      assert report.reported_user_id == target.id
    end

    test "accepts a gallery report and sets gallery_id" do
      gallery = gallery_fixture(confirmed_user_fixture())
      report = report_fixture(gallery_id: gallery.id)

      assert report.gallery_id == gallery.id
    end

    test "accepts a commission report and sets commission_id" do
      commission = commission_fixture(confirmed_user_fixture())
      report = report_fixture(commission_id: commission.id)

      assert report.commission_id == commission.id
    end
  end

  describe "create_report/3 target-count rejection" do
    test "rejects a report with zero targets" do
      attrs = %{
        "reason" => "no target",
        "user_agent" => "TB/1.0",
        "rule_id" => rule_fixture().id
      }

      assert {:error, changeset} =
               Reports.create_report(actor(), attrs, [])

      assert %{target: ["must reference exactly one target"]} = errors_on(changeset)
    end
  end

  describe "creation_changeset/4 exactly-one validation" do
    test "rejects a report referencing two targets" do
      image = image_fixture()
      target = confirmed_user_fixture()

      changeset =
        Report.creation_changeset(
          %Report{image_id: image.id, reported_user_id: target.id},
          %{"reason" => "two targets", "user_agent" => "TB/1.0"},
          attribution(),
          rule_fixture()
        )

      refute changeset.valid?
      assert %{target: ["must reference exactly one target"]} = errors_on(changeset)
    end

    test "rejects a report referencing no target" do
      changeset =
        Report.creation_changeset(
          %Report{},
          %{"reason" => "no target", "user_agent" => "TB/1.0"},
          attribution(),
          rule_fixture()
        )

      refute changeset.valid?
      assert %{target: ["must reference exactly one target"]} = errors_on(changeset)
    end
  end

  describe "reports_reportable_association_null DB constraint" do
    test "allows an all-NULL (orphan) report row" do
      assert {:ok, report} =
               %Report{}
               |> Ecto.Changeset.change(%{
                 ip: %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 32},
                 fingerprint: "ffff",
                 reason: "orphan"
               })
               |> Repo.insert()

      assert Enum.all?(Report.target_columns(), &is_nil(Map.get(report, &1)))
    end

    test "rejects a report row with two non-NULL columns" do
      image = image_fixture()
      gallery = gallery_fixture(confirmed_user_fixture())

      assert {:error, changeset} =
               %Report{}
               |> Ecto.Changeset.change(%{
                 ip: %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 32},
                 fingerprint: "ffff",
                 reason: "two targets",
                 image_id: image.id,
                 gallery_id: gallery.id
               })
               |> Ecto.Changeset.check_constraint(:target,
                 name: "reports_reportable_association_null"
               )
               |> Repo.insert()

      assert %{target: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "orphaned report helpers" do
    setup do
      {:ok, orphan} =
        %Report{}
        |> Ecto.Changeset.change(%{
          ip: %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 32},
          fingerprint: "ffff",
          reason: "orphan"
        })
        |> Repo.insert()

      %{orphan: orphan}
    end

    test "all target columns are nil", %{orphan: orphan} do
      assert Enum.all?(Report.target_columns(), &is_nil(Map.get(orphan, &1)))
    end

    test "preload_targets/1 leaves every target association nil", %{orphan: orphan} do
      preloaded = Reports.preload_targets(orphan)

      assert preloaded.image == nil
      assert preloaded.comment == nil
      assert preloaded.post == nil
      assert preloaded.reported_user == nil
      assert preloaded.commission == nil
      assert preloaded.conversation == nil
      assert preloaded.gallery == nil
    end
  end

  describe "close_reports/2 via the target-column API" do
    test "closes open reports for an image" do
      image = image_fixture()
      report = report_fixture(image_id: image.id)
      admin = admin_user_fixture()

      assert report.open

      assert {:ok, {1, _ids}} = Reports.close_reports(admin, image_id: image.id)

      closed = Reports.get_report!(report.id)
      refute closed.open
      assert closed.state == "closed"
      assert closed.admin_id == admin.id
    end

    test "closes open reports for a user" do
      target = confirmed_user_fixture()
      report = report_fixture(reported_user_id: target.id)
      admin = admin_user_fixture()

      assert {:ok, {1, _ids}} = Reports.close_reports(admin, reported_user_id: target.id)

      closed = Reports.get_report!(report.id)
      refute closed.open
      assert closed.state == "closed"
    end
  end

  describe "SearchIndex.as_json/1" do
    defp indexed_report(report) do
      report
      |> Repo.preload([:user, :admin])
      |> Reports.preload_targets()
    end

    test "image report carries legacy reportable_type, reportable_id and image_id" do
      owner = confirmed_user_fixture()
      image = image_fixture(%{user_id: owner.id})
      report = report_fixture(image_id: image.id)

      json = SearchIndex.as_json(indexed_report(report))

      assert json.reportable_type == "Image"
      assert json.reportable_id == image.id
      assert json.image_id == image.id
      assert String.downcase(owner.name) in json.related_users
    end

    test "user report carries legacy reportable_type and reportable_id" do
      target = confirmed_user_fixture()
      report = report_fixture(reported_user_id: target.id)

      json = SearchIndex.as_json(indexed_report(report))

      assert json.reportable_type == "User"
      assert json.reportable_id == target.id
      assert String.downcase(target.name) in json.related_users
    end

    test "gallery report includes the gallery owner in related_users" do
      owner = confirmed_user_fixture()
      gallery = gallery_fixture(owner)
      report = report_fixture(gallery_id: gallery.id)

      json = SearchIndex.as_json(indexed_report(report))

      assert json.reportable_type == "Gallery"
      assert json.reportable_id == gallery.id
      assert json.related_users == [String.downcase(owner.name)]
      assert json.related_user_ids == [owner.id]
    end

    test "commission report carries legacy reportable_type and reportable_id" do
      owner = confirmed_user_fixture()
      commission = commission_fixture(owner)
      report = report_fixture(commission_id: commission.id)

      json = SearchIndex.as_json(indexed_report(report))

      assert json.reportable_type == "Commission"
      assert json.reportable_id == commission.id
      assert json.related_users == [String.downcase(owner.name)]
    end

    test "orphan report serializes without crashing" do
      {:ok, orphan} =
        %Report{}
        |> Ecto.Changeset.change(%{
          ip: %Postgrex.INET{address: {127, 0, 0, 1}, netmask: 32},
          fingerprint: "ffff",
          reason: "orphan"
        })
        |> Repo.insert()

      json = SearchIndex.as_json(indexed_report(orphan))

      assert json.reportable_type == nil
      assert json.reportable_id == nil
      assert json.image_id == nil
      assert json.related_users == []
      assert json.related_user_ids == []
    end
  end
end
