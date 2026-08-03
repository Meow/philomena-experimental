defmodule Philomena.UserIpsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.UserIps.load_ip_profile/2`.

  These pin parse-before-authorization error precedence, IPv4/IPv6
  canonicalization, the staff-only sensitive-identity gate, and the assembled
  `IpProfile` shape.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures, only: [actor: 0, actor: 1]
  import Philomena.BansFixtures
  import Philomena.UserIpsFixtures
  import Philomena.UsersFixtures

  alias Philomena.UserIps
  alias Philomena.UserIps.IpProfile

  describe "load_ip_profile/2" do
    test "a moderator gets the users seen on the address and the covering subnet bans" do
      user = confirmed_user_fixture()
      user_ip_fixture(user, "203.0.113.50")
      subnet_ban_fixture(%{"specification" => "203.0.113.0/24"})

      assert {:ok, %IpProfile{ip: ip, user_ips: user_ips, subnet_bans: subnet_bans}} =
               UserIps.load_ip_profile(actor(moderator_user_fixture()), "203.0.113.50")

      assert %Postgrex.INET{} = ip
      assert user.id in Enum.map(user_ips, & &1.user.id)
      refute subnet_bans == []
    end

    test "an admin may load an IP profile" do
      assert {:ok, %IpProfile{}} =
               UserIps.load_ip_profile(actor(admin_user_fixture()), "203.0.113.1")
    end

    test "a staffer submitting an unparsable address is not-found" do
      assert UserIps.load_ip_profile(actor(moderator_user_fixture()), "not-an-ip") ==
               {:error, :not_found}
    end

    test "a valid unmatched address returns an empty typed profile" do
      assert {:ok, %IpProfile{user_ips: [], subnet_bans: []}} =
               UserIps.load_ip_profile(actor(moderator_user_fixture()), "198.51.100.42")
    end

    test "an equivalent IPv6 spelling is canonicalized" do
      assert {:ok, %IpProfile{ip: %Postgrex.INET{address: address}}} =
               UserIps.load_ip_profile(
                 actor(moderator_user_fixture()),
                 "2001:0DB8:0:0:0:0:0:1"
               )

      assert address == {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}
    end

    test "a regular user is unauthorized, even for a valid address" do
      assert UserIps.load_ip_profile(actor(confirmed_user_fixture()), "203.0.113.1") ==
               {:error, :unauthorized}
    end

    test "an unprivileged viewer passing garbage is not-found" do
      assert UserIps.load_ip_profile(actor(confirmed_user_fixture()), "garbage") ==
               {:error, :not_found}
    end

    test "an anonymous viewer is unauthorized" do
      assert UserIps.load_ip_profile(actor(), "203.0.113.1") == {:error, :unauthorized}
    end
  end
end
