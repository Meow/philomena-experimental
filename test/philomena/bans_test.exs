defmodule Philomena.BansTest do
  @moduledoc """
  Context-level tests for the profile-page ban lookups on `Philomena.Bans`:
  `subnet_bans_for_ip/1` and `fingerprint_bans_for/1`.

  These pin the subnet-containment match, the exact fingerprint match, the
  newest-first ordering, and the empty result for a value no ban covers.
  """

  use Philomena.DataCase, async: true

  import Philomena.BansFixtures
  import Philomena.UserIpsFixtures, only: [inet: 1]

  alias Philomena.Bans

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

  # Stamps created_at directly so the newest-first ordering can be observed
  # without relying on insertion timing.
  defp set_created_at(schema, id, created_at) do
    schema
    |> where(id: ^id)
    |> Repo.update_all(set: [created_at: created_at])
  end
end
