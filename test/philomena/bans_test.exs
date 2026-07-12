defmodule Philomena.BansTest do
  @moduledoc """
  Context-level tests for `Philomena.Bans`.

  Two groups. The profile-page lookups (`subnet_bans_for_ip/1`,
  `fingerprint_bans_for/1`) pin subnet-containment, exact fingerprint match,
  newest-first ordering, and the empty result for an uncovered value.

  The admin ban management functions (index/new/create/edit/update/delete for
  user, subnet, and fingerprint bans) pin the per-role authorization matrix, the
  non-castable/unknown-id split, the admin-only restriction on deletes, the
  invalid-ip shapes on the subnet index and new form, and the byte-exact
  moderation-log type/subject_path/body written on each successful write.

  The actor here is a plain `User.t()` or `nil`, matching what the controller
  hands in as `conn.assigns.current_user`.
  """

  use Philomena.DataCase, async: true

  import Philomena.BansFixtures
  import Philomena.UserIpsFixtures, only: [inet: 1]
  import Philomena.UsersFixtures

  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Bans

  @pagination %{page_number: 1, page_size: 25}

  defp only_moderation_log!, do: Repo.one!(ModerationLog)

  defp moderation_log_count, do: Repo.aggregate(ModerationLog, :count)

  describe "subnet_bans_for_ip/1" do
    test "returns a subnet ban whose specification contains the address" do
      ban = subnet_ban_fixture(%{"specification" => "203.0.113.0/24"})

      assert ban.id in Enum.map(Bans.subnet_bans_for_ip(inet("203.0.113.50")), & &1.id)
    end

    test "excludes a subnet ban that does not contain the address" do
      subnet_ban_fixture(%{"specification" => "203.0.113.0/24"})

      assert Bans.subnet_bans_for_ip(inet("198.51.100.1")) == []
    end

    test "orders matching bans newest first" do
      older = subnet_ban_fixture(%{"specification" => "203.0.113.0/24"})
      newer = subnet_ban_fixture(%{"specification" => "203.0.113.0/25"})

      set_created_at(Bans.Subnet, older.id, ~U[2020-01-01 00:00:00Z])
      set_created_at(Bans.Subnet, newer.id, ~U[2024-01-01 00:00:00Z])

      ids = Enum.map(Bans.subnet_bans_for_ip(inet("203.0.113.50")), & &1.id)
      assert Enum.find_index(ids, &(&1 == newer.id)) < Enum.find_index(ids, &(&1 == older.id))
    end
  end

  describe "fingerprint_bans_for/1" do
    test "returns a fingerprint ban matching the fingerprint" do
      ban = fingerprint_ban_fixture(%{"fingerprint" => "c0ffee1234"})

      assert ban.id in Enum.map(Bans.fingerprint_bans_for("c0ffee1234"), & &1.id)
    end

    test "excludes a ban for a different fingerprint" do
      fingerprint_ban_fixture(%{"fingerprint" => "c0ffee1234"})

      assert Bans.fingerprint_bans_for("deadbeef") == []
    end

    test "orders matching bans newest first" do
      older = fingerprint_ban_fixture(%{"fingerprint" => "abc123"})
      newer = fingerprint_ban_fixture(%{"fingerprint" => "abc123"})

      set_created_at(Bans.Fingerprint, older.id, ~U[2020-01-01 00:00:00Z])
      set_created_at(Bans.Fingerprint, newer.id, ~U[2024-01-01 00:00:00Z])

      ids = Enum.map(Bans.fingerprint_bans_for("abc123"), & &1.id)
      assert ids == [newer.id, older.id]
    end
  end

  describe "admin_user_bans/3" do
    test "a moderator gets the paginated user bans" do
      moderator = moderator_user_fixture()
      ban = user_ban_fixture()

      assert {:ok, page} = Bans.admin_user_bans(moderator, %{}, @pagination)
      assert %Scrivener.Page{} = page
      assert ban.id in Enum.map(page.entries, & &1.id)
    end

    test "an admin gets the paginated user bans" do
      admin = admin_user_fixture()
      ban = user_ban_fixture()

      assert {:ok, page} = Bans.admin_user_bans(admin, %{}, @pagination)
      assert ban.id in Enum.map(page.entries, & &1.id)
    end

    test "a regular user is not authorized" do
      assert Bans.admin_user_bans(confirmed_user_fixture(), %{}, @pagination) ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Bans.admin_user_bans(nil, %{}, @pagination) == {:error, :unauthorized}
    end

    test "the bq branch matches a ban by its generated ban id" do
      moderator = moderator_user_fixture()
      ban = user_ban_fixture()
      _other = user_ban_fixture()

      assert {:ok, page} =
               Bans.admin_user_bans(moderator, %{"bq" => ban.generated_ban_id}, @pagination)

      assert Enum.map(page.entries, & &1.id) == [ban.id]
    end

    test "the bq branch matches a ban by the banned user's name" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture(%{name: "bantargetname"})
      ban = user_ban_fixture(target)

      assert {:ok, page} =
               Bans.admin_user_bans(moderator, %{"bq" => "bantargetname"}, @pagination)

      assert ban.id in Enum.map(page.entries, & &1.id)
    end

    test "the user_id branch filters to that user's bans" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()
      ban = user_ban_fixture(target)
      _other = user_ban_fixture()

      assert {:ok, page} =
               Bans.admin_user_bans(moderator, %{"user_id" => "#{target.id}"}, @pagination)

      assert Enum.map(page.entries, & &1.id) == [ban.id]
    end

    test "a non-integer user_id filter raises Ecto.Query.CastError" do
      moderator = moderator_user_fixture()

      assert_raise Ecto.Query.CastError, fn ->
        Bans.admin_user_bans(moderator, %{"user_id" => "abc"}, @pagination)
      end
    end
  end

  describe "new_user_ban/2" do
    test "a moderator gets the target and a changeset for a known user id" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()

      assert {:ok, {loaded, %Ecto.Changeset{}}} = Bans.new_user_ban(moderator, "#{target.id}")
      assert loaded.id == target.id
    end

    test "an unknown but castable user id has no target" do
      moderator = moderator_user_fixture()

      assert Bans.new_user_ban(moderator, "2147483647") == {:error, :no_target}
    end

    test "a non-castable user id has no target" do
      moderator = moderator_user_fixture()

      assert Bans.new_user_ban(moderator, "abc") == {:error, :no_target}
    end

    test "a nil user id has no target" do
      moderator = moderator_user_fixture()

      assert Bans.new_user_ban(moderator, nil) == {:error, :no_target}
    end

    test "a regular user is not authorized" do
      target = confirmed_user_fixture()

      assert Bans.new_user_ban(confirmed_user_fixture(), "#{target.id}") ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      target = confirmed_user_fixture()
      assert Bans.new_user_ban(nil, "#{target.id}") == {:error, :unauthorized}
    end
  end

  describe "create_user_ban/2" do
    test "a moderator creates a ban and a moderation log is written" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()

      assert {:ok, ban} = Bans.create_user_ban(moderator, valid_user_ban_attrs(target))

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Admin.UserBan:create"
      assert log.subject_path == "/admin/user_bans"
      assert log.body == "Created a user ban #{ban.generated_ban_id}"
    end

    test "an admin creates a ban" do
      admin = admin_user_fixture()
      target = confirmed_user_fixture()

      assert {:ok, _ban} = Bans.create_user_ban(admin, valid_user_ban_attrs(target))
    end

    test "invalid attributes return a changeset and write no log" do
      moderator = moderator_user_fixture()
      target = confirmed_user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Bans.create_user_ban(moderator, %{valid_user_ban_attrs(target) | "reason" => ""})

      assert moderation_log_count() == 0
    end

    test "a regular user is not authorized and creates nothing" do
      target = confirmed_user_fixture()

      assert Bans.create_user_ban(confirmed_user_fixture(), valid_user_ban_attrs(target)) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an anonymous visitor is not authorized" do
      target = confirmed_user_fixture()

      assert Bans.create_user_ban(nil, valid_user_ban_attrs(target)) == {:error, :unauthorized}
    end
  end

  describe "load_user_ban_for_edit/2" do
    test "a moderator loads the ban with the banned user preloaded" do
      moderator = moderator_user_fixture()
      ban = user_ban_fixture()

      assert {:ok, {loaded, %Ecto.Changeset{}}} = Bans.load_user_ban_for_edit(moderator, ban.id)
      assert loaded.id == ban.id
      refute match?(%Ecto.Association.NotLoaded{}, loaded.user)
    end

    test "an admin loads the ban" do
      admin = admin_user_fixture()
      ban = user_ban_fixture()

      assert {:ok, {loaded, _}} = Bans.load_user_ban_for_edit(admin, ban.id)
      assert loaded.id == ban.id
    end

    test "an unknown id is not found for a moderator" do
      moderator = moderator_user_fixture()
      assert Bans.load_user_ban_for_edit(moderator, 2_147_483_647) == {:error, :not_found}
    end

    test "an unknown id is not found for an admin" do
      admin = admin_user_fixture()
      assert Bans.load_user_ban_for_edit(admin, 2_147_483_647) == {:error, :not_found}
    end

    test "a non-castable id is not found for a moderator" do
      moderator = moderator_user_fixture()
      assert Bans.load_user_ban_for_edit(moderator, "abc") == {:error, :not_found}
    end

    test "a non-castable id is not found for an admin" do
      admin = admin_user_fixture()
      assert Bans.load_user_ban_for_edit(admin, "abc") == {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = user_ban_fixture()

      assert Bans.load_user_ban_for_edit(confirmed_user_fixture(), ban.id) ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      ban = user_ban_fixture()
      assert Bans.load_user_ban_for_edit(nil, ban.id) == {:error, :unauthorized}
    end
  end

  describe "update_user_ban/3" do
    test "a moderator updates the ban and a moderation log is written" do
      moderator = moderator_user_fixture()
      ban = user_ban_fixture()

      assert {:ok, updated} = Bans.update_user_ban(moderator, ban.id, %{"reason" => "Changed"})
      assert updated.reason == "Changed"

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Admin.UserBan:update"
      assert log.subject_path == "/admin/user_bans"
      assert log.body == "Updated a user ban #{ban.generated_ban_id}"
    end

    test "an admin updates the ban" do
      admin = admin_user_fixture()
      ban = user_ban_fixture()

      assert {:ok, _} = Bans.update_user_ban(admin, ban.id, %{"reason" => "Changed"})
    end

    test "invalid attributes return a changeset and write no log" do
      moderator = moderator_user_fixture()
      ban = user_ban_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Bans.update_user_ban(moderator, ban.id, %{"reason" => ""})

      assert moderation_log_count() == 0
    end

    test "an unknown id is not found" do
      moderator = moderator_user_fixture()

      assert Bans.update_user_ban(moderator, 2_147_483_647, %{"reason" => "x"}) ==
               {:error, :not_found}
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()
      assert Bans.update_user_ban(moderator, "abc", %{"reason" => "x"}) == {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = user_ban_fixture()

      assert Bans.update_user_ban(confirmed_user_fixture(), ban.id, %{"reason" => "x"}) ==
               {:error, :unauthorized}
    end
  end

  describe "delete_user_ban/2" do
    test "an admin deletes the ban and a moderation log is written" do
      admin = admin_user_fixture()
      ban = user_ban_fixture()

      assert {:ok, deleted} = Bans.delete_user_ban(admin, ban.id)
      assert deleted.id == ban.id
      refute Repo.get(Bans.User, ban.id)

      log = only_moderation_log!()
      assert log.user_id == admin.id
      assert log.type == "Admin.UserBan:delete"
      assert log.subject_path == "/admin/user_bans"
      assert log.body == "Deleted a user ban #{ban.generated_ban_id}"
    end

    test "a moderator with a real ban id is not authorized to delete" do
      # Deleting is admin-only; a moderator passes the module-level authorize and
      # loads the ban, then fails the admin-only delete check.
      moderator = moderator_user_fixture()
      ban = user_ban_fixture()

      assert Bans.delete_user_ban(moderator, ban.id) == {:error, :unauthorized}
      assert Repo.get(Bans.User, ban.id)
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown id is not found, not unauthorized" do
      # The load runs before the admin-only delete check, so a missing ban is
      # not_found even for a moderator who could never delete it.
      moderator = moderator_user_fixture()
      assert Bans.delete_user_ban(moderator, 2_147_483_647) == {:error, :not_found}
    end

    test "an admin with an unknown id is not found" do
      admin = admin_user_fixture()
      assert Bans.delete_user_ban(admin, 2_147_483_647) == {:error, :not_found}
    end

    test "a non-castable id is not found for a moderator" do
      moderator = moderator_user_fixture()
      assert Bans.delete_user_ban(moderator, "abc") == {:error, :not_found}
    end

    test "a non-castable id is not found for an admin" do
      admin = admin_user_fixture()
      assert Bans.delete_user_ban(admin, "abc") == {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = user_ban_fixture()
      assert Bans.delete_user_ban(confirmed_user_fixture(), ban.id) == {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      ban = user_ban_fixture()
      assert Bans.delete_user_ban(nil, ban.id) == {:error, :unauthorized}
    end
  end

  describe "admin_subnet_bans/3" do
    test "a moderator gets the paginated subnet bans" do
      moderator = moderator_user_fixture()
      ban = subnet_ban_fixture()

      assert {:ok, page} = Bans.admin_subnet_bans(moderator, %{}, @pagination)
      assert ban.id in Enum.map(page.entries, & &1.id)
    end

    test "the bq branch matches a ban by its generated ban id" do
      moderator = moderator_user_fixture()
      ban = subnet_ban_fixture()
      _other = subnet_ban_fixture()

      assert {:ok, page} =
               Bans.admin_subnet_bans(moderator, %{"bq" => ban.generated_ban_id}, @pagination)

      assert Enum.map(page.entries, & &1.id) == [ban.id]
    end

    test "the ip branch matches a subnet ban containing the address" do
      moderator = moderator_user_fixture()
      ban = subnet_ban_fixture(%{"specification" => "203.0.113.0/24"})

      assert {:ok, page} =
               Bans.admin_subnet_bans(moderator, %{"ip" => "203.0.113.50"}, @pagination)

      assert ban.id in Enum.map(page.entries, & &1.id)
    end

    test "an invalid ip in the ip branch returns the invalid-ip error" do
      moderator = moderator_user_fixture()

      assert Bans.admin_subnet_bans(moderator, %{"ip" => "not-an-ip"}, @pagination) ==
               {:error, {:invalid_ip, "not-an-ip"}}
    end

    test "a regular user is not authorized" do
      assert Bans.admin_subnet_bans(confirmed_user_fixture(), %{}, @pagination) ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Bans.admin_subnet_bans(nil, %{}, @pagination) == {:error, :unauthorized}
    end
  end

  describe "new_subnet_ban/2" do
    test "a moderator gets a blank subnet for a nil specification" do
      moderator = moderator_user_fixture()

      assert {:ok, %Bans.Subnet{specification: nil}} = Bans.new_subnet_ban(moderator, nil)
    end

    test "a moderator gets a prefilled subnet for a valid specification" do
      moderator = moderator_user_fixture()

      assert {:ok, %Bans.Subnet{specification: spec}} =
               Bans.new_subnet_ban(moderator, "203.0.113.0/24")

      refute is_nil(spec)
    end

    test "an invalid specification returns the invalid-ip error" do
      moderator = moderator_user_fixture()

      assert Bans.new_subnet_ban(moderator, "not-an-ip") == {:error, {:invalid_ip, "not-an-ip"}}
    end

    test "a regular user is not authorized even with an invalid specification" do
      # Authorization runs ahead of specification parsing, so an unprivileged
      # actor gets the unauthorized error rather than the invalid-ip one.
      assert Bans.new_subnet_ban(confirmed_user_fixture(), "not-an-ip") ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Bans.new_subnet_ban(nil, "203.0.113.0/24") == {:error, :unauthorized}
    end
  end

  describe "create_subnet_ban/2" do
    test "a moderator creates a ban and a moderation log is written" do
      moderator = moderator_user_fixture()

      assert {:ok, ban} = Bans.create_subnet_ban(moderator, valid_subnet_ban_attrs())

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Admin.SubnetBan:create"
      assert log.subject_path == "/admin/subnet_bans"
      assert log.body == "Created a subnet ban #{ban.generated_ban_id}"
    end

    test "invalid attributes return a changeset and write no log" do
      moderator = moderator_user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Bans.create_subnet_ban(moderator, %{valid_subnet_ban_attrs() | "reason" => ""})

      assert moderation_log_count() == 0
    end

    test "a regular user is not authorized and creates nothing" do
      assert Bans.create_subnet_ban(confirmed_user_fixture(), valid_subnet_ban_attrs()) ==
               {:error, :unauthorized}

      assert moderation_log_count() == 0
    end

    test "an anonymous visitor is not authorized" do
      assert Bans.create_subnet_ban(nil, valid_subnet_ban_attrs()) == {:error, :unauthorized}
    end
  end

  describe "load_subnet_ban_for_edit/2" do
    test "a moderator loads the ban" do
      moderator = moderator_user_fixture()
      ban = subnet_ban_fixture()

      assert {:ok, {loaded, %Ecto.Changeset{}}} = Bans.load_subnet_ban_for_edit(moderator, ban.id)
      assert loaded.id == ban.id
    end

    test "an unknown id is not found for a moderator" do
      moderator = moderator_user_fixture()
      assert Bans.load_subnet_ban_for_edit(moderator, 2_147_483_647) == {:error, :not_found}
    end

    test "an unknown id is not found for an admin" do
      admin = admin_user_fixture()
      assert Bans.load_subnet_ban_for_edit(admin, 2_147_483_647) == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()
      assert Bans.load_subnet_ban_for_edit(moderator, "abc") == {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = subnet_ban_fixture()

      assert Bans.load_subnet_ban_for_edit(confirmed_user_fixture(), ban.id) ==
               {:error, :unauthorized}
    end
  end

  describe "update_subnet_ban/3" do
    test "a moderator updates the ban and a moderation log is written" do
      moderator = moderator_user_fixture()
      ban = subnet_ban_fixture()

      assert {:ok, updated} = Bans.update_subnet_ban(moderator, ban.id, %{"reason" => "Changed"})
      assert updated.reason == "Changed"

      log = only_moderation_log!()
      assert log.type == "Admin.SubnetBan:update"
      assert log.subject_path == "/admin/subnet_bans"
      assert log.body == "Updated a subnet ban #{ban.generated_ban_id}"
    end

    test "invalid attributes return a changeset and write no log" do
      moderator = moderator_user_fixture()
      ban = subnet_ban_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Bans.update_subnet_ban(moderator, ban.id, %{"reason" => ""})

      assert moderation_log_count() == 0
    end

    test "an unknown id is not found" do
      moderator = moderator_user_fixture()

      assert Bans.update_subnet_ban(moderator, 2_147_483_647, %{"reason" => "x"}) ==
               {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = subnet_ban_fixture()

      assert Bans.update_subnet_ban(confirmed_user_fixture(), ban.id, %{"reason" => "x"}) ==
               {:error, :unauthorized}
    end
  end

  describe "delete_subnet_ban/2" do
    test "an admin deletes the ban and a moderation log is written" do
      admin = admin_user_fixture()
      ban = subnet_ban_fixture()

      assert {:ok, deleted} = Bans.delete_subnet_ban(admin, ban.id)
      assert deleted.id == ban.id
      refute Repo.get(Bans.Subnet, ban.id)

      log = only_moderation_log!()
      assert log.type == "Admin.SubnetBan:delete"
      assert log.subject_path == "/admin/subnet_bans"
      assert log.body == "Deleted a subnet ban #{ban.generated_ban_id}"
    end

    test "a moderator with a real ban id is not authorized to delete" do
      moderator = moderator_user_fixture()
      ban = subnet_ban_fixture()

      assert Bans.delete_subnet_ban(moderator, ban.id) == {:error, :unauthorized}
      assert Repo.get(Bans.Subnet, ban.id)
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown id is not found" do
      moderator = moderator_user_fixture()
      assert Bans.delete_subnet_ban(moderator, 2_147_483_647) == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      admin = admin_user_fixture()
      assert Bans.delete_subnet_ban(admin, "abc") == {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = subnet_ban_fixture()
      assert Bans.delete_subnet_ban(confirmed_user_fixture(), ban.id) == {:error, :unauthorized}
    end
  end

  describe "admin_fingerprint_bans/3" do
    test "a moderator gets the paginated fingerprint bans" do
      moderator = moderator_user_fixture()
      ban = fingerprint_ban_fixture()

      assert {:ok, page} = Bans.admin_fingerprint_bans(moderator, %{}, @pagination)
      assert ban.id in Enum.map(page.entries, & &1.id)
    end

    test "the bq branch matches a ban by its generated ban id" do
      moderator = moderator_user_fixture()
      ban = fingerprint_ban_fixture()
      _other = fingerprint_ban_fixture()

      assert {:ok, page} =
               Bans.admin_fingerprint_bans(
                 moderator,
                 %{"bq" => ban.generated_ban_id},
                 @pagination
               )

      assert Enum.map(page.entries, & &1.id) == [ban.id]
    end

    test "the fingerprint branch filters to an exact fingerprint" do
      moderator = moderator_user_fixture()
      ban = fingerprint_ban_fixture(%{"fingerprint" => "c0ffee1234"})
      _other = fingerprint_ban_fixture(%{"fingerprint" => "deadbeef"})

      assert {:ok, page} =
               Bans.admin_fingerprint_bans(
                 moderator,
                 %{"fingerprint" => "c0ffee1234"},
                 @pagination
               )

      assert Enum.map(page.entries, & &1.id) == [ban.id]
    end

    test "a regular user is not authorized" do
      assert Bans.admin_fingerprint_bans(confirmed_user_fixture(), %{}, @pagination) ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Bans.admin_fingerprint_bans(nil, %{}, @pagination) == {:error, :unauthorized}
    end
  end

  describe "new_fingerprint_ban/2" do
    test "a moderator gets a changeset prefilled with the fingerprint" do
      moderator = moderator_user_fixture()

      assert {:ok, %Ecto.Changeset{} = changeset} =
               Bans.new_fingerprint_ban(moderator, "c0ffee1234")

      assert Ecto.Changeset.get_field(changeset, :fingerprint) == "c0ffee1234"
    end

    test "a regular user is not authorized" do
      assert Bans.new_fingerprint_ban(confirmed_user_fixture(), "c0ffee1234") ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Bans.new_fingerprint_ban(nil, "c0ffee1234") == {:error, :unauthorized}
    end
  end

  describe "create_fingerprint_ban/2" do
    test "a moderator creates a ban and a moderation log is written" do
      moderator = moderator_user_fixture()

      assert {:ok, ban} = Bans.create_fingerprint_ban(moderator, valid_fingerprint_ban_attrs())

      log = only_moderation_log!()
      assert log.user_id == moderator.id
      assert log.type == "Admin.FingerprintBan:create"
      assert log.subject_path == "/admin/fingerprint_bans"
      assert log.body == "Created a fingerprint ban #{ban.generated_ban_id}"
    end

    test "invalid attributes return a changeset and write no log" do
      moderator = moderator_user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Bans.create_fingerprint_ban(moderator, %{
                 valid_fingerprint_ban_attrs()
                 | "reason" => ""
               })

      assert moderation_log_count() == 0
    end

    test "a regular user is not authorized" do
      assert Bans.create_fingerprint_ban(confirmed_user_fixture(), valid_fingerprint_ban_attrs()) ==
               {:error, :unauthorized}
    end

    test "an anonymous visitor is not authorized" do
      assert Bans.create_fingerprint_ban(nil, valid_fingerprint_ban_attrs()) ==
               {:error, :unauthorized}
    end
  end

  describe "load_fingerprint_ban_for_edit/2" do
    test "a moderator loads the ban" do
      moderator = moderator_user_fixture()
      ban = fingerprint_ban_fixture()

      assert {:ok, {loaded, %Ecto.Changeset{}}} =
               Bans.load_fingerprint_ban_for_edit(moderator, ban.id)

      assert loaded.id == ban.id
    end

    test "an unknown id is not found for a moderator" do
      moderator = moderator_user_fixture()
      assert Bans.load_fingerprint_ban_for_edit(moderator, 2_147_483_647) == {:error, :not_found}
    end

    test "an unknown id is not found for an admin" do
      admin = admin_user_fixture()
      assert Bans.load_fingerprint_ban_for_edit(admin, 2_147_483_647) == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      moderator = moderator_user_fixture()
      assert Bans.load_fingerprint_ban_for_edit(moderator, "abc") == {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = fingerprint_ban_fixture()

      assert Bans.load_fingerprint_ban_for_edit(confirmed_user_fixture(), ban.id) ==
               {:error, :unauthorized}
    end
  end

  describe "update_fingerprint_ban/3" do
    test "a moderator updates the ban and a moderation log is written" do
      moderator = moderator_user_fixture()
      ban = fingerprint_ban_fixture()

      assert {:ok, updated} =
               Bans.update_fingerprint_ban(moderator, ban.id, %{"reason" => "Changed"})

      assert updated.reason == "Changed"

      log = only_moderation_log!()
      assert log.type == "Admin.FingerprintBan:update"
      assert log.subject_path == "/admin/fingerprint_bans"
      assert log.body == "Updated a fingerprint ban #{ban.generated_ban_id}"
    end

    test "invalid attributes return a changeset and write no log" do
      moderator = moderator_user_fixture()
      ban = fingerprint_ban_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Bans.update_fingerprint_ban(moderator, ban.id, %{"reason" => ""})

      assert moderation_log_count() == 0
    end

    test "an unknown id is not found" do
      moderator = moderator_user_fixture()

      assert Bans.update_fingerprint_ban(moderator, 2_147_483_647, %{"reason" => "x"}) ==
               {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = fingerprint_ban_fixture()

      assert Bans.update_fingerprint_ban(confirmed_user_fixture(), ban.id, %{"reason" => "x"}) ==
               {:error, :unauthorized}
    end
  end

  describe "delete_fingerprint_ban/2" do
    test "an admin deletes the ban and a moderation log is written" do
      admin = admin_user_fixture()
      ban = fingerprint_ban_fixture()

      assert {:ok, deleted} = Bans.delete_fingerprint_ban(admin, ban.id)
      assert deleted.id == ban.id
      refute Repo.get(Bans.Fingerprint, ban.id)

      log = only_moderation_log!()
      assert log.type == "Admin.FingerprintBan:delete"
      assert log.subject_path == "/admin/fingerprint_bans"
      assert log.body == "Deleted a fingerprint ban #{ban.generated_ban_id}"
    end

    test "a moderator with a real ban id is not authorized to delete" do
      moderator = moderator_user_fixture()
      ban = fingerprint_ban_fixture()

      assert Bans.delete_fingerprint_ban(moderator, ban.id) == {:error, :unauthorized}
      assert Repo.get(Bans.Fingerprint, ban.id)
      assert moderation_log_count() == 0
    end

    test "a moderator with an unknown id is not found" do
      moderator = moderator_user_fixture()
      assert Bans.delete_fingerprint_ban(moderator, 2_147_483_647) == {:error, :not_found}
    end

    test "a non-castable id is not found" do
      admin = admin_user_fixture()
      assert Bans.delete_fingerprint_ban(admin, "abc") == {:error, :not_found}
    end

    test "a regular user is not authorized" do
      ban = fingerprint_ban_fixture()

      assert Bans.delete_fingerprint_ban(confirmed_user_fixture(), ban.id) ==
               {:error, :unauthorized}
    end
  end

  # Controller-shaped attrs (string keys) a user ban insert requires: a target,
  # a reason, and a valid_until (a RelativeDate a plain DateTime casts fine).
  defp valid_user_ban_attrs(target) do
    %{
      "user_id" => target.id,
      "reason" => "Test ban reason",
      "valid_until" => DateTime.add(DateTime.utc_now(:second), 365, :day)
    }
  end

  defp valid_subnet_ban_attrs do
    %{
      "specification" => "203.0.113.0/24",
      "reason" => "Test subnet reason",
      "valid_until" => DateTime.add(DateTime.utc_now(:second), 365, :day)
    }
  end

  defp valid_fingerprint_ban_attrs do
    %{
      "fingerprint" => "c1836fd10ff8f27a",
      "reason" => "Test fingerprint reason",
      "valid_until" => DateTime.add(DateTime.utc_now(:second), 365, :day)
    }
  end

  # Stamps created_at directly so the newest-first ordering can be observed
  # without relying on insertion timing.
  defp set_created_at(schema, id, created_at) do
    schema
    |> where(id: ^id)
    |> Repo.update_all(set: [created_at: created_at])
  end
end
