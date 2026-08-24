defmodule Philomena.UserWorkersTest do
  use Philomena.DataCase, async: false
  use Patch

  import Philomena.AttributionFixtures
  import Philomena.ImagesFixtures
  import Philomena.UserFingerprintsFixtures
  import Philomena.UserIpsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Bans.User, as: UserBan
  alias Philomena.ImageFaves.ImageFave
  alias Philomena.Images
  alias Philomena.ImageVotes.ImageVote
  alias Philomena.Repo
  alias Philomena.UserEraseWorker
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.UserIps.UserIp
  alias Philomena.UserUnvoteWorker
  alias Philomena.UserWipeWorker
  alias Philomena.Users.User
  alias Philomena.Users.UserDownvoteWipe

  test "the unvote worker removes all requested interactions and repairs counters" do
    patch(UserDownvoteWipe, :reindex, :ok)

    user = confirmed_user_fixture()
    downvoted = image_fixture()
    faved = image_fixture()

    assert {:ok, _image} = Images.create_vote(actor(user), downvoted.id, false)
    assert {:ok, _image} = Images.create_fave(actor(user), faved.id)

    assert :ok = UserUnvoteWorker.perform(user.id, true)

    refute Repo.get_by(ImageVote, user_id: user.id, image_id: downvoted.id)
    refute Repo.get_by(ImageVote, user_id: user.id, image_id: faved.id)
    refute Repo.get_by(ImageFave, user_id: user.id, image_id: faved.id)

    assert %{score: 0, downvotes_count: 0} = Repo.reload!(downvoted)
    assert %{score: 0, upvotes_count: 0, faves_count: 0} = Repo.reload!(faved)
    assert %{image_votes_count: 0, image_faves_count: 0} = Repo.reload!(user)
  end

  test "the wipe worker erases stored attribution and contact information" do
    user = confirmed_user_fixture()
    user_ip_fixture(user, "198.51.100.8")
    user_fingerprint_fixture(user, "worker-fingerprint")

    image =
      image_fixture(
        user_id: user.id,
        ip: inet("198.51.100.8"),
        fingerprint: "worker-fingerprint"
      )

    assert %User{id: user_id} = UserWipeWorker.perform(user.id)
    assert user_id == user.id

    wiped_user = Repo.reload!(user)
    assert wiped_user.email =~ ~r/^deactivated[0-9a-f]{32}@example\.com$/
    refute Repo.exists?(from ip in UserIp, where: ip.user_id == ^user.id)
    refute Repo.exists?(from fp in UserFingerprint, where: fp.user_id == ^user.id)

    wiped_image = Repo.reload!(image)
    assert to_string(wiped_image.ip) == "127.0.1.1"
    assert wiped_image.fingerprint == "ffff"
  end

  test "the erase worker clears the profile and bans the account" do
    moderator = moderator_user_fixture()

    user =
      user_fixture()
      |> User.description_changeset(%{
        description: "public profile text",
        personal_title: "A title"
      })
      |> Repo.update!()

    assert :ok = UserEraseWorker.perform(user.id, moderator.id)

    erased = Repo.reload!(user)
    assert erased.description in [nil, ""]
    assert erased.personal_title in [nil, ""]

    assert Repo.exists?(
             from ban in UserBan,
               where: ban.user_id == ^user.id and ban.banning_user_id == ^moderator.id,
               where: ban.reason == "Site abuse" and ban.enabled == true
           )
  end
end
