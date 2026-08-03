defmodule Philomena.UserFingerprintsTest do
  @moduledoc """
  Context-level tests for the controller-facing
  `Philomena.UserFingerprints.load_fingerprint_profile/2`.

  These pin canonicalization, validation-before-authorization, the staff-only
  sensitive-identity gate, and the distinction between an invalid fingerprint
  and a valid fingerprint with no matching history.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures, only: [actor: 0, actor: 1]
  import Philomena.BansFixtures
  import Philomena.UserFingerprintsFixtures
  import Philomena.UsersFixtures

  alias Philomena.UserFingerprints
  alias Philomena.UserFingerprints.FingerprintProfile

  describe "valid_format?/1" do
    test "accepts supported legacy and current formats" do
      assert UserFingerprints.valid_format?("c637334158")
      assert UserFingerprints.valid_format?("d015c342859dde3")
    end

    test "rejects malformed or noncanonical values" do
      refute UserFingerprints.valid_format?("anything")
      refute UserFingerprints.valid_format?("D015C342859DDE3")
      refute UserFingerprints.valid_format?(nil)
    end
  end

  describe "load_fingerprint_profile/2" do
    test "a moderator gets the users seen with the fingerprint and the matching bans" do
      user = confirmed_user_fixture()
      user_fingerprint_fixture(user, "d015c342859dde3")
      fingerprint_ban_fixture(%{"fingerprint" => "d015c342859dde3"})

      assert {:ok,
              %FingerprintProfile{
                fingerprint: "d015c342859dde3",
                user_fingerprints: user_fingerprints,
                fingerprint_bans: fingerprint_bans
              }} =
               UserFingerprints.load_fingerprint_profile(
                 actor(moderator_user_fixture()),
                 "  D015C342859DDE3  "
               )

      assert user.id in Enum.map(user_fingerprints, & &1.user.id)
      refute fingerprint_bans == []
    end

    test "an admin may load a fingerprint profile" do
      assert {:ok, %FingerprintProfile{}} =
               UserFingerprints.load_fingerprint_profile(
                 actor(admin_user_fixture()),
                 "c637334158"
               )
    end

    test "a valid unmatched fingerprint returns an empty typed profile" do
      assert {:ok, %FingerprintProfile{user_fingerprints: [], fingerprint_bans: []}} =
               UserFingerprints.load_fingerprint_profile(
                 actor(moderator_user_fixture()),
                 "d11111111111111"
               )
    end

    test "an invalid fingerprint is not found for a moderator" do
      assert UserFingerprints.load_fingerprint_profile(
               actor(moderator_user_fixture()),
               "not-a-fingerprint"
             ) == {:error, :not_found}
    end

    test "a regular user is unauthorized for a valid fingerprint" do
      assert UserFingerprints.load_fingerprint_profile(
               actor(confirmed_user_fixture()),
               "d11111111111111"
             ) ==
               {:error, :unauthorized}
    end

    test "invalid input is not found before the permission gate" do
      assert UserFingerprints.load_fingerprint_profile(
               actor(confirmed_user_fixture()),
               "garbage"
             ) == {:error, :not_found}
    end

    test "an anonymous viewer is unauthorized for a valid fingerprint" do
      assert UserFingerprints.load_fingerprint_profile(actor(), "d11111111111111") ==
               {:error, :unauthorized}
    end
  end
end
