defmodule Philomena.ImagesConcurrencyTest do
  use Philomena.ConcurrentDataCase

  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo

  import Philomena.AttributionFixtures
  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

  test "concurrent approvals transition once and increment uploader statistics once" do
    uploader = confirmed_user_fixture()
    moderator = moderator_user_fixture()
    image = image_fixture(user_id: uploader.id, approved: false)
    initial_count = Repo.reload!(uploader).images_count

    results =
      concurrently([
        fn -> Images.approve_image(actor(moderator), image.id) end,
        fn -> Images.approve_image(actor(moderator), image.id) end
      ])

    assert Enum.count(results, &match?({:ok, %Image{}}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, %{errors: [approved: {"must be false", []}]}}, &1)
           ) == 1

    assert Repo.get!(Image, image.id).approved
    assert Repo.reload!(uploader).images_count == initial_count + 1
    assert Repo.aggregate(ModerationLog, :count) == 1
  end
end
