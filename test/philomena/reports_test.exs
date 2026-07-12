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
  authorization matrices (including the plain/moderator-unauthorized vs
  admin-not-found split on an unknown id), the `ReportPage` struct shape and its
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

  alias Philomena.Commissions.Commission
  alias Philomena.Conversations.Conversation
  alias Philomena.Galleries.Gallery
  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Reports
  alias Philomena.Reports.Report
  alias Philomena.Reports.ReportPage
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

  describe "load_report_index/3" do
    test "an anonymous viewer is unauthorized" do
      assert Reports.load_report_index(nil, %{}, @pagination) == {:error, :unauthorized}
    end

    test "a regular user is unauthorized" do
      assert Reports.load_report_index(confirmed_user_fixture(), %{}, @pagination) ==
               {:error, :unauthorized}
    end

    test "a moderator is authorized" do
      assert {:ok, %ReportPage{}} =
               Reports.load_report_index(moderator_user_fixture(), %{}, @pagination)
    end

    test "an admin gets the assembled page struct with the searched report" do
      admin = admin_user_fixture()
      image = image_fixture()
      report = report_fixture({"Image", image.id})
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{reports: reports, my_reports: my, system_reports: system}} =
               Reports.load_report_index(admin, %{}, @pagination)

      assert %Scrivener.Page{} = reports
      assert is_list(my)
      assert is_list(system)

      # The open, non-own, non-system report is in the default searched list.
      assert report.id in Enum.map(reports.entries, & &1.id)
    end

    test "the default view returns empty lists on an empty table" do
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{reports: reports, my_reports: [], system_reports: []}} =
               Reports.load_report_index(admin_user_fixture(), %{}, @pagination)

      assert Enum.empty?(reports.entries)
    end

    test "the actor's own open reports populate my_reports and leave the searched list" do
      admin = admin_user_fixture()
      image = image_fixture()
      report = report_fixture({"Image", image.id})
      {:ok, _} = Reports.claim_report(admin, to_string(report.id))
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{my_reports: my, reports: reports}} =
               Reports.load_report_index(admin, %{}, @pagination)

      assert report.id in Enum.map(my, & &1.id)
      refute report.id in Enum.map(reports.entries, & &1.id)
    end

    test "open system reports populate system_reports" do
      admin = admin_user_fixture()
      image = image_fixture()
      rule = Philomena.RulesFixtures.rule_fixture()

      {:ok, report} =
        Reports.create_system_report({"Image", image.id}, rule.name, "System reason")

      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{system_reports: system, reports: reports}} =
               Reports.load_report_index(admin, %{}, @pagination)

      assert report.id in Enum.map(system, & &1.id)

      # The system report is excluded from the default searched list.
      refute report.id in Enum.map(reports.entries, & &1.id)
    end

    test "the rq search branch drives reports and empties the own and system lists" do
      admin = admin_user_fixture()
      image = image_fixture()
      report = report_fixture({"Image", image.id})

      # A report that would land in my_reports in the default view.
      {:ok, _} = Reports.claim_report(admin, to_string(report.id))
      SearchHelpers.reindex_all!(Report)

      assert {:ok, %ReportPage{reports: reports, my_reports: [], system_reports: []}} =
               Reports.load_report_index(admin, %{"rq" => "*"}, @pagination)

      assert report.id in Enum.map(reports.entries, & &1.id)
    end

    test "a malformed rq raises MatchError" do
      # An authorized actor reaches the query compile, which returns an error
      # tuple that the {:ok, query} match rejects.
      assert_raise MatchError, fn ->
        Reports.load_report_index(admin_user_fixture(), %{"rq" => "("}, @pagination)
      end
    end
  end

  describe "load_report/2" do
    setup do
      image = image_fixture()
      %{image: image, report: report_fixture({"Image", image.id})}
    end

    test "a moderator loads a report with the reportable resolved", %{
      image: image,
      report: report
    } do
      assert {:ok, loaded} = Reports.load_report(moderator_user_fixture(), to_string(report.id))
      assert loaded.id == report.id
      assert loaded.reportable_type == "Image"
      assert loaded.reportable.id == image.id
    end

    test "an admin loads a report", %{report: report} do
      assert {:ok, loaded} = Reports.load_report(admin_user_fixture(), to_string(report.id))
      assert loaded.id == report.id
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.load_report(confirmed_user_fixture(), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized", %{report: report} do
      assert Reports.load_report(nil, to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert Reports.load_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Reports.load_report(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.load_report(admin_user_fixture(), "not-a-number") == {:error, :not_found}
    end
  end

  describe "claim_report/2" do
    setup do
      image = image_fixture()
      %{report: report_fixture({"Image", image.id})}
    end

    test "a moderator claims a report", %{report: report} do
      moderator = moderator_user_fixture()

      assert {:ok, claimed} = Reports.claim_report(moderator, to_string(report.id))
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

      {:ok, claimed} = Reports.claim_report(first, to_string(report.id))
      assert claimed.admin_id == first.id

      assert {:ok, reclaimed} = Reports.claim_report(second, to_string(report.id))
      assert reclaimed.admin_id == second.id
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.claim_report(confirmed_user_fixture(), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized", %{report: report} do
      assert Reports.claim_report(nil, to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert Reports.claim_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Reports.claim_report(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.claim_report(admin_user_fixture(), "not-a-number") == {:error, :not_found}
    end
  end

  describe "unclaim_report/2" do
    setup do
      image = image_fixture()
      report = report_fixture({"Image", image.id})
      {:ok, _} = Reports.claim_report(admin_user_fixture(), to_string(report.id))
      %{report: report}
    end

    test "a moderator unclaims a report", %{report: report} do
      assert {:ok, unclaimed} =
               Reports.unclaim_report(moderator_user_fixture(), to_string(report.id))

      assert unclaimed.admin_id == nil
      assert unclaimed.state == "open"
      assert unclaimed.open
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.unclaim_report(confirmed_user_fixture(), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized", %{report: report} do
      assert Reports.unclaim_report(nil, to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert Reports.unclaim_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Reports.unclaim_report(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.unclaim_report(admin_user_fixture(), "not-a-number") == {:error, :not_found}
    end
  end

  describe "close_report/2" do
    setup do
      image = image_fixture()
      %{report: report_fixture({"Image", image.id})}
    end

    test "a moderator closes a report", %{report: report} do
      moderator = moderator_user_fixture()

      assert {:ok, closed} = Reports.close_report(moderator, to_string(report.id))
      assert closed.admin_id == moderator.id
      assert closed.state == "closed"
      refute closed.open
    end

    test "a regular user is unauthorized", %{report: report} do
      assert Reports.close_report(confirmed_user_fixture(), to_string(report.id)) ==
               {:error, :unauthorized}
    end

    test "an anonymous actor is unauthorized", %{report: report} do
      assert Reports.close_report(nil, to_string(report.id)) == {:error, :unauthorized}
    end

    test "an unknown well-formed id is unauthorized for a moderator, not-found for an admin" do
      assert Reports.close_report(moderator_user_fixture(), "2147483647") ==
               {:error, :unauthorized}

      assert Reports.close_report(admin_user_fixture(), "2147483647") == {:error, :not_found}
    end

    test "a non-integer id is not-found" do
      assert Reports.close_report(admin_user_fixture(), "not-a-number") == {:error, :not_found}
    end
  end

  describe "mod_notes/3" do
    setup do
      image = image_fixture()
      report = report_fixture({"Image", image.id})

      note =
        mod_note_fixture(moderator_user_fixture(), %{
          "notable_type" => "Report",
          "notable_id" => report.id
        })

      %{report: report, note: note}
    end

    test "a moderator gets the rendered mod notes for the report", %{report: report, note: note} do
      # The renderer zips each note with its rendered body into a {note, body}
      # tuple, so the identity renderer pairs each note with itself.
      notes = Reports.mod_notes(moderator_user_fixture(), report, & &1)
      assert is_list(notes)
      assert note.id in Enum.map(notes, fn {loaded, _body} -> loaded.id end)
    end

    test "a regular user gets nil", %{report: report} do
      assert Reports.mod_notes(confirmed_user_fixture(), report, & &1) == nil
    end

    test "an anonymous viewer gets nil", %{report: report} do
      assert Reports.mod_notes(nil, report, & &1) == nil
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

  describe "load_gallery_for_report/2" do
    # Backs the report form (a GET-guarded action): the not-banned check runs
    # first, then the gallery is loaded and authorized for :show.

    setup do
      %{gallery: gallery_fixture(confirmed_user_fixture())}
    end

    test "a banned actor is rejected before any loading, even with a garbage id" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_gallery_for_report(actor, "abc") == {:error, :ban}
    end

    test "an anonymous actor loads the report form for a gallery", %{gallery: gallery} do
      assert {:ok, {%Gallery{} = loaded, %Ecto.Changeset{} = changeset}} =
               Reports.load_gallery_for_report(actor(nil), "#{gallery.id}")

      assert loaded.id == gallery.id

      # The changeset is over a Report addressed at this gallery.
      assert %Report{} = changeset.data
      assert changeset.data.reportable_type == "Gallery"
      assert changeset.data.reportable_id == gallery.id
    end

    # A well-formed id naming no row authorizes nil; no ordinary rule permits it,
    # so an anonymous actor is unauthorized, while an admin (whose grant covers
    # nil) instead sees the missing row as not-found.
    test "a well-formed id naming no row is unauthorized for anonymous, not-found for admin" do
      assert Reports.load_gallery_for_report(actor(nil), "999999999") == {:error, :unauthorized}

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

    test "a well-formed id naming no row is unauthorized for anonymous, not-found for admin" do
      assert Reports.load_gallery_for_report_creation(actor(nil), "999999999") ==
               {:error, :unauthorized}

      assert Reports.load_gallery_for_report_creation(actor(admin_user_fixture()), "999999999") ==
               {:error, :not_found}
    end

    test "an id that cannot name a row is not found" do
      assert Reports.load_gallery_for_report_creation(actor(confirmed_user_fixture()), "abc") ==
               {:error, :not_found}
    end
  end

  describe "load_user_for_report/2" do
    # Backs the profile report form (a GET-guarded action): the not-banned check
    # runs first, then the user is looked up by slug and authorized for :show.

    setup do
      %{reported: confirmed_user_fixture()}
    end

    test "a banned actor is rejected before any loading, even with a garbage slug" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_user_for_report(actor, "no-such-user") == {:error, :ban}
    end

    test "an anonymous actor loads the report form for a user", %{reported: reported} do
      assert {:ok, {%User{} = loaded, %Ecto.Changeset{} = changeset}} =
               Reports.load_user_for_report(actor(nil), reported.slug)

      assert loaded.id == reported.id

      # The changeset is over a Report addressed at this user.
      assert %Report{} = changeset.data
      assert changeset.data.reportable_type == "User"
      assert changeset.data.reportable_id == reported.id
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
    # Backs the commission report form (a GET-guarded action): the not-banned
    # check runs first, then the user and their commission are looked up by slug.
    # Viewing the commission report form needs no permission, so the lookup runs
    # no authorization.

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
      assert changeset.data.reportable_type == "Commission"
      assert changeset.data.reportable_id == commission.id
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
    # Backs the conversation report form (a GET-guarded action): the not-banned
    # check runs first, then the conversation is loaded by slug and authorized
    # for :show (participants, moderators, and admins).

    setup do
      from = confirmed_user_fixture()
      to = confirmed_user_fixture()
      %{conversation: conversation_fixture(from, to), from: from, to: to}
    end

    test "a banned actor is rejected before any loading, even with a garbage slug" do
      actor = actor(confirmed_user_fixture(), ban: @ban)

      assert Reports.load_conversation_for_report(actor, "no-such-slug") == {:error, :ban}
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
      assert changeset.data.reportable_type == "Conversation"
      assert changeset.data.reportable_id == conversation.id
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
end
