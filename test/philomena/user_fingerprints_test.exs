defmodule Philomena.UserFingerprintsTest do
  @moduledoc """
  Context-level tests for the controller-facing
  `Philomena.UserFingerprints.load_fingerprint_profile/2`.

  These pin the staff-only gate and the raw-string matching: any value returns a
  (possibly empty) profile, so there is no not-found case, and the assembled
  `FingerprintProfile` carries the users seen with the fingerprint and the
  matching fingerprint bans.
  """

  use Philomena.DataCase, async: true

  import Philomena.BansFixtures
  import Philomena.UserFingerprintsFixtures
  import Philomena.UsersFixtures

  alias Philomena.UserFingerprints
  alias Philomena.UserFingerprints.FingerprintProfile

  describe "load_fingerprint_profile/2" do
    test "a moderator gets the users seen with the fingerprint and the matching bans" do
      user = confirmed_user_fixture()
      user_fingerprint_fixture(user, "c1836fd10ff8f27a")
      fingerprint_ban_fixture(%{"fingerprint" => "c1836fd10ff8f27a"})

      assert {:ok,
              %FingerprintProfile{
                fingerprint: "c1836fd10ff8f27a",
                user_fingerprints: user_fingerprints,
                fingerprint_bans: fingerprint_bans
              }} =
               UserFingerprints.load_fingerprint_profile(
                 moderator_user_fixture(),
                 "c1836fd10ff8f27a"
               )

      assert user.id in Enum.map(user_fingerprints, & &1.user.id)
      refute fingerprint_bans == []
    end

    test "an admin may load a fingerprint profile" do
      assert {:ok, %FingerprintProfile{}} =
               UserFingerprints.load_fingerprint_profile(admin_user_fixture(), "anything")
    end

    test "any raw string is accepted and returns a possibly-empty profile" do
      assert {:ok, %FingerprintProfile{user_fingerprints: [], fingerprint_bans: []}} =
               UserFingerprints.load_fingerprint_profile(
                 moderator_user_fixture(),
                 "no-such-fingerprint"
               )
    end

    test "a regular user is unauthorized" do
      assert UserFingerprints.load_fingerprint_profile(confirmed_user_fixture(), "anything") ==
               {:error, :unauthorized}
    end

    test "an anonymous viewer is unauthorized" do
      assert UserFingerprints.load_fingerprint_profile(nil, "anything") == {:error, :unauthorized}
    end
  end
end
