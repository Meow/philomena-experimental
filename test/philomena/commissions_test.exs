defmodule Philomena.CommissionsTest do
  @moduledoc """
  Context-level tests for the actor-first commission and commission-item loaders
  and writers on `Philomena.Commissions`.

  These pin the owner-only gates (with the staff bypass on commission
  management, and its absence on item management), the bespoke
  `:no_verified_links` shape for a profile without a verified artist link, the
  ban/write-access ordering, the raising item lookup, and the create/update/
  delete round-trips.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures
  import Philomena.ArtistLinksFixtures
  import Philomena.CommissionsFixtures
  import Philomena.TagsFixtures
  import Philomena.UserIpsFixtures
  import Philomena.UsersFixtures
  import Philomena.ReportsFixtures

  alias Philomena.Commissions
  alias Philomena.Commissions.Commission
  alias Philomena.Commissions.Item
  alias Philomena.Repo
  alias Philomena.Reports
  alias Philomena.Reports.Report

  # A truthy ban value in the shape production passes; only its presence matters
  # to the write-access and not-banned checks the loaders run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  defp artist_tag_fixture do
    tag_fixture(name: "artist:test-commission-artist-#{System.unique_integer([:positive])}")
  end

  # A confirmed user holding a verified artist link, which the commission gates
  # require the profile to have.
  defp verified_user_with_link do
    user = confirmed_user_fixture()
    verified_artist_link_fixture(user, artist_tag_fixture())
    user
  end

  defp commission_params(attrs \\ %{}) do
    Enum.into(attrs, %{
      "information" => "Test commission information",
      "contact" => "Test contact info",
      "will_create" => "Test subjects",
      "open" => true
    })
  end

  defp item_params(attrs \\ %{}) do
    Enum.into(attrs, %{
      "item_type" => "Sketch",
      "description" => "Test item description",
      "base_price" => 20
    })
  end

  describe "load_commission_for_show/1" do
    test "returns the user and commission for a user who has one" do
      user = confirmed_user_fixture()
      commission = commission_fixture(user)
      commission_item_fixture(commission)

      assert {:ok, {loaded_user, loaded}} = Commissions.load_commission_for_show(user.slug)
      assert loaded_user.id == user.id
      assert loaded.id == commission.id
      assert is_list(loaded.items)
    end

    test "an unknown slug is not-found" do
      assert Commissions.load_commission_for_show("no-such-user") == {:error, :not_found}
    end

    test "a user without a commission is not-found" do
      assert Commissions.load_commission_for_show(confirmed_user_fixture().slug) ==
               {:error, :not_found}
    end
  end

  describe "load_commission_for_new/2" do
    test "the owner with a verified link and no commission gets the user" do
      user = verified_user_with_link()

      assert {:ok, loaded} = Commissions.load_commission_for_new(actor(user), user.slug)
      assert loaded.id == user.id
    end

    test "a moderator may open the new form for another user (staff bypass)" do
      user = verified_user_with_link()

      assert {:ok, loaded} =
               Commissions.load_commission_for_new(actor(moderator_user_fixture()), user.slug)

      assert loaded.id == user.id
    end

    test "a banned actor is rejected before any gating" do
      user = verified_user_with_link()

      assert Commissions.load_commission_for_new(actor(user, ban: @ban), user.slug) ==
               {:error, :ban}
    end

    test "an owner whose profile already has a commission is unauthorized" do
      user = verified_user_with_link()
      commission_fixture(user)

      assert Commissions.load_commission_for_new(actor(user), user.slug) ==
               {:error, :unauthorized}
    end

    test "an unrelated user may not open another owner's new form" do
      user = verified_user_with_link()

      assert Commissions.load_commission_for_new(actor(confirmed_user_fixture()), user.slug) ==
               {:error, :unauthorized}
    end

    test "an owner without a verified link gets the no-verified-links shape" do
      user = confirmed_user_fixture()

      assert Commissions.load_commission_for_new(actor(user), user.slug) ==
               {:error, :no_verified_links}
    end
  end

  describe "create_commission/3" do
    test "the owner creates a commission" do
      user = verified_user_with_link()

      assert {:ok, {loaded_user, %Commission{} = commission}} =
               Commissions.create_commission(actor(user), user.slug, commission_params())

      assert loaded_user.id == user.id
      assert Repo.get(Commission, commission.id).user_id == user.id
    end

    test "an actor with no fingerprint is unauthorized" do
      user = verified_user_with_link()

      assert Commissions.create_commission(
               actor(user, fingerprint: nil),
               user.slug,
               commission_params()
             ) == {:error, :unauthorized}
    end
  end

  describe "load_commission_for_edit/2" do
    test "the owner loads their commission and a changeset" do
      user = verified_user_with_link()
      commission = commission_fixture(user)

      assert {:ok, {loaded_user, loaded, %Ecto.Changeset{}}} =
               Commissions.load_commission_for_edit(actor(user), user.slug)

      assert loaded_user.id == user.id
      assert loaded.id == commission.id
    end

    test "a profile without a commission is not-found" do
      user = verified_user_with_link()

      assert Commissions.load_commission_for_edit(actor(user), user.slug) == {:error, :not_found}
    end

    test "an unrelated user may not edit another owner's commission" do
      user = verified_user_with_link()
      commission_fixture(user)

      assert Commissions.load_commission_for_edit(actor(confirmed_user_fixture()), user.slug) ==
               {:error, :unauthorized}
    end
  end

  describe "update_commission/3" do
    test "the owner updates their commission" do
      user = verified_user_with_link()
      commission = commission_fixture(user)

      assert {:ok, {_user, updated}} =
               Commissions.update_commission(
                 actor(user),
                 user.slug,
                 commission_params(%{"information" => "Updated information"})
               )

      assert updated.id == commission.id
      assert Repo.get(Commission, commission.id).information == "Updated information"
    end
  end

  describe "delete_commission/2" do
    test "the owner deletes their commission" do
      user = verified_user_with_link()
      commission = commission_fixture(user)

      assert {:ok, %Commission{}} = Commissions.delete_commission(actor(user), user.slug)
      assert Repo.get(Commission, commission.id) == nil
    end
  end

  describe "delete_commission/3" do
    test "closes the commission's open reports and nulls the target FK while keeping the row" do
      commission = commission_fixture(confirmed_user_fixture())
      report = report_fixture(commission_id: commission.id)
      admin = admin_user_fixture()

      assert report.open
      assert report.commission_id == commission.id

      assert {:ok, _commission} = Commissions.delete_commission(commission, admin, nil)

      closed = Reports.get_report!(report.id)
      refute closed.open
      assert closed.state == "closed"
      assert closed.admin_id == admin.id
      # The FK is nilified by the database, orphaning the report as audit trail.
      assert closed.commission_id == nil
      assert Enum.all?(Report.target_columns(), &is_nil(Map.get(closed, &1)))

      refute Repo.get(Commission, commission.id)
    end
  end

  describe "load_item_for_new/2" do
    test "the owner loads the item form" do
      user = verified_user_with_link()
      commission = commission_fixture(user)

      assert {:ok, {loaded_user, loaded, %Ecto.Changeset{data: %Item{}}}} =
               Commissions.load_item_for_new(actor(user), user.slug)

      assert loaded_user.id == user.id
      assert loaded.id == commission.id
    end

    test "items have no staff bypass, so a moderator is unauthorized" do
      user = verified_user_with_link()
      commission_fixture(user)

      assert Commissions.load_item_for_new(actor(moderator_user_fixture()), user.slug) ==
               {:error, :unauthorized}
    end
  end

  describe "create_item/3" do
    test "the owner adds an item" do
      user = verified_user_with_link()
      commission = commission_fixture(user)

      assert {:ok, loaded_user} =
               Commissions.create_item(actor(user), user.slug, item_params())

      assert loaded_user.id == user.id

      assert Repo.aggregate(from(i in Item, where: i.commission_id == ^commission.id), :count) ==
               1
    end
  end

  describe "load_item_for_edit/3" do
    test "the owner loads an item for editing" do
      user = verified_user_with_link()
      commission = commission_fixture(user)
      item = commission_item_fixture(commission)

      assert {:ok, {loaded_user, _commission, loaded_item, %Ecto.Changeset{}}} =
               Commissions.load_item_for_edit(actor(user), user.slug, "#{item.id}")

      assert loaded_user.id == user.id
      assert loaded_item.id == item.id
    end

    test "an item id that does not belong to the commission raises" do
      user = verified_user_with_link()
      commission_fixture(user)

      assert_raise Ecto.NoResultsError, fn ->
        Commissions.load_item_for_edit(actor(user), user.slug, "2147483647")
      end
    end
  end

  describe "delete_item/3" do
    test "the owner deletes an item" do
      user = verified_user_with_link()
      commission = commission_fixture(user)
      item = commission_item_fixture(commission)

      assert {:ok, loaded_user} = Commissions.delete_item(actor(user), user.slug, "#{item.id}")
      assert loaded_user.id == user.id
      assert Repo.get(Item, item.id) == nil
    end
  end

  describe "search_directory/2" do
    @pagination [page: 1, page_size: 25]

    # A commission the directory query surfaces: open, with an item, whose owner
    # has recent IP activity (the query excludes artists idle over two weeks).
    defp directory_commission do
      user = verified_user_with_link()
      commission = commission_fixture(user)
      commission_item_fixture(commission)
      user_ip_fixture(user)
      {user, commission}
    end

    test "an empty search returns a page and a fresh search changeset" do
      {_user, commission} = directory_commission()

      assert {%Scrivener.Page{} = page, %Ecto.Changeset{}} =
               Commissions.search_directory(%{}, @pagination)

      assert commission.id in Enum.map(page.entries, & &1.id)
    end

    test "an invalid search returns an empty page and the invalid changeset" do
      directory_commission()

      assert {%Scrivener.Page{entries: []} = page, %Ecto.Changeset{} = changeset} =
               Commissions.search_directory(%{"price_min" => "not-a-number"}, @pagination)

      assert page.total_entries == 0
      refute changeset.valid?
    end
  end

  describe "preload_commission/1" do
    test "preloads the commission of a user" do
      user = confirmed_user_fixture()
      commission_fixture(user)

      loaded = Commissions.preload_commission(user)
      refute match?(%Ecto.Association.NotLoaded{}, loaded.commission)
      assert loaded.commission.user_id == user.id
    end

    test "returns nil for nil" do
      assert Commissions.preload_commission(nil) == nil
    end
  end
end
