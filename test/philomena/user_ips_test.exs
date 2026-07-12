defmodule Philomena.UserIpsTest do
  @moduledoc """
  Context-level tests for the controller-facing `Philomena.UserIps.load_ip_profile/2`.

  These pin the staff-only gate, the authorize-before-parse ordering (an
  unprivileged viewer passing garbage input is answered unauthorized, not
  not-found), the not-found for an unparsable address a staffer submits, and the
  assembled `IpProfile` shape carrying the users seen on the address and the
  subnet bans covering it.
  """

  use Philomena.DataCase, async: true

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
               UserIps.load_ip_profile(moderator_user_fixture(), "203.0.113.50")

      assert %Postgrex.INET{} = ip
      assert user.id in Enum.map(user_ips, & &1.user.id)
      refute subnet_bans == []
    end

    test "an admin may load an IP profile" do
      assert {:ok, %IpProfile{}} = UserIps.load_ip_profile(admin_user_fixture(), "203.0.113.1")
    end

    test "a staffer submitting an unparsable address is not-found" do
      assert UserIps.load_ip_profile(moderator_user_fixture(), "not-an-ip") ==
               {:error, :not_found}
    end

    test "a regular user is unauthorized, even for a valid address" do
      assert UserIps.load_ip_profile(confirmed_user_fixture(), "203.0.113.1") ==
               {:error, :unauthorized}
    end

    test "an unprivileged viewer passing garbage is unauthorized, not not-found" do
      # Authorization runs before the address is parsed, so the missing
      # permission wins over the malformed input.
      assert UserIps.load_ip_profile(confirmed_user_fixture(), "garbage") ==
               {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized" do
      assert UserIps.load_ip_profile(nil, "203.0.113.1") == {:error, :unauthorized}
    end
  end
end
