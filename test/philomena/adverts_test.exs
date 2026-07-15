defmodule Philomena.AdvertsTest do
  @moduledoc """
  Context-level tests for the actor-first advert loaders and writers on
  `Philomena.Adverts`.

  Advert administration is admin/`Advert`-role-map-moderator only; these pin the
  module-level `:index` gate (a plain moderator is rejected before any advert
  loads), the per-instance unknown-id asymmetry (an admin may act on the `nil`
  load and gets not-found, while an `Advert`-role moderator cannot and gets
  unauthorized), the byte-exact moderation logs each write emits, and that the
  image-upload pipeline runs on the real fixture uploads.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures, only: [actor: 0, actor: 1]
  import Philomena.AdvertsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Adverts
  alias Philomena.Adverts.Advert
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo

  @pagination %{page_number: 1, page_size: 25}

  defp moderation_logs, do: Repo.all(ModerationLog)

  defp no_moderation_logs! do
    assert Repo.aggregate(ModerationLog, :count) == 0
  end

  # Advert params in the shape the admin form posts, with a real 700x85 upload.
  defp advert_params(attrs \\ %{}) do
    Enum.into(attrs, %{
      "title" => "Created Advert #{System.unique_integer([:positive])}",
      "link" => "https://example.com/created-#{System.unique_integer([:positive])}",
      "start_date" => "now",
      "finish_date" => "1 year from now",
      "restrictions" => "none",
      "image" => png_upload()
    })
  end

  describe "load_adverts/2" do
    test "an admin and an Advert-role moderator may list, others may not" do
      _advert = advert_fixture()

      assert {:ok, %Scrivener.Page{}} =
               Adverts.load_adverts(actor(admin_user_fixture()), @pagination)

      assert {:ok, %Scrivener.Page{}} =
               Adverts.load_adverts(actor(role_moderator_fixture("Advert")), @pagination)

      assert Adverts.load_adverts(actor(moderator_user_fixture()), @pagination) ==
               {:error, :unauthorized}

      assert Adverts.load_adverts(actor(confirmed_user_fixture()), @pagination) ==
               {:error, :unauthorized}

      assert Adverts.load_adverts(actor(), @pagination) == {:error, :unauthorized}
    end

    test "the listing is ordered by finish date descending" do
      now = DateTime.utc_now(:second)
      sooner = advert_fixture(%{finish_date: DateTime.add(now, 1, :hour)})
      later = advert_fixture(%{finish_date: DateTime.add(now, 500, :day)})

      assert {:ok, page} = Adverts.load_adverts(actor(admin_user_fixture()), @pagination)

      ids = Enum.map(page.entries, & &1.id)
      assert Enum.find_index(ids, &(&1 == later.id)) < Enum.find_index(ids, &(&1 == sooner.id))
    end
  end

  describe "new_advert/1" do
    test "an admin and an Advert-role moderator get a changeset, others do not" do
      assert {:ok, %Ecto.Changeset{data: %Advert{}}} =
               Adverts.new_advert(actor(admin_user_fixture()))

      assert {:ok, %Ecto.Changeset{data: %Advert{}}} =
               Adverts.new_advert(actor(role_moderator_fixture("Advert")))

      assert Adverts.new_advert(actor(moderator_user_fixture())) == {:error, :unauthorized}
      assert Adverts.new_advert(actor()) == {:error, :unauthorized}
    end
  end

  describe "create_advert/2" do
    test "an admin creates an advert through the upload pipeline and writes a byte-exact log" do
      admin = admin_user_fixture()

      assert {:ok, %Advert{} = advert} =
               Adverts.create_advert(
                 actor(admin),
                 advert_params(%{"title" => "Advert To Create"})
               )

      assert advert.title == "Advert To Create"
      assert Repo.get_by(Advert, title: "Advert To Create")

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Admin.Advert:create"
      assert log.body == "Created advert #{advert.id}"
      assert log.subject_path == "/admin/adverts"
    end

    test "an Advert-role moderator creates an advert" do
      assert {:ok, %Advert{}} =
               Adverts.create_advert(actor(role_moderator_fixture("Advert")), advert_params())
    end

    test "a plain moderator is unauthorized and writes no log" do
      assert Adverts.create_advert(
               actor(moderator_user_fixture()),
               advert_params(%{"title" => "nope"})
             ) ==
               {:error, :unauthorized}

      refute Repo.get_by(Advert, title: "nope")
      no_moderation_logs!()
    end

    test "a blank title is a changeset error and writes no log" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Adverts.create_advert(actor(admin_user_fixture()), advert_params(%{"title" => ""}))

      refute changeset.valid?
      no_moderation_logs!()
    end
  end

  describe "load_advert_for_edit/2" do
    test "an admin loads the advert and a changeset" do
      advert = advert_fixture()

      assert {:ok, {loaded, %Ecto.Changeset{}}} =
               Adverts.load_advert_for_edit(actor(admin_user_fixture()), "#{advert.id}")

      assert loaded.id == advert.id
    end

    test "a plain moderator is rejected by the module gate" do
      advert = advert_fixture()

      assert Adverts.load_advert_for_edit(actor(moderator_user_fixture()), "#{advert.id}") ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      assert Adverts.load_advert_for_edit(actor(admin_user_fixture()), "abc") ==
               {:error, :not_found}
    end

    test "an unknown id is not-found for an admin but unauthorized for an Advert-role moderator" do
      assert Adverts.load_advert_for_edit(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}

      assert Adverts.load_advert_for_edit(actor(role_moderator_fixture("Advert")), "2147483647") ==
               {:error, :unauthorized}
    end
  end

  describe "update_advert/3" do
    test "an admin updates an advert and writes a byte-exact log" do
      admin = admin_user_fixture()
      advert = advert_fixture(%{title: "Before Advert"})

      assert {:ok, updated} =
               Adverts.update_advert(actor(admin), "#{advert.id}", %{"title" => "After Advert"})

      assert updated.title == "After Advert"
      assert Repo.get(Advert, advert.id).title == "After Advert"

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Admin.Advert:update"
      assert log.body == "Updated advert #{advert.id}"
      assert log.subject_path == "/admin/adverts"
    end

    test "a plain moderator is rejected by the module gate and writes no log" do
      advert = advert_fixture(%{title: "Unchanged Advert"})

      assert Adverts.update_advert(actor(moderator_user_fixture()), "#{advert.id}", %{
               "title" => "changed"
             }) == {:error, :unauthorized}

      assert Repo.get(Advert, advert.id).title == "Unchanged Advert"
      no_moderation_logs!()
    end

    test "an unknown id is not-found for an admin but unauthorized for an Advert-role moderator" do
      assert Adverts.update_advert(actor(admin_user_fixture()), "2147483647", %{"title" => "x"}) ==
               {:error, :not_found}

      assert Adverts.update_advert(actor(role_moderator_fixture("Advert")), "2147483647", %{
               "title" => "x"
             }) == {:error, :unauthorized}
    end

    test "a blank title is a changeset error and writes no log" do
      advert = advert_fixture(%{title: "Keep Advert"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Adverts.update_advert(actor(admin_user_fixture()), "#{advert.id}", %{"title" => ""})

      refute changeset.valid?
      assert Repo.get(Advert, advert.id).title == "Keep Advert"
      no_moderation_logs!()
    end
  end

  describe "update_advert_image/3" do
    test "an admin updates the image through the upload pipeline and writes a byte-exact log" do
      admin = admin_user_fixture()
      advert = advert_fixture()

      assert {:ok, %Advert{}} =
               Adverts.update_advert_image(actor(admin), "#{advert.id}", %{
                 "image" => png_upload()
               })

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Admin.Advert.Image:update"
      assert log.body == "Updated image for advert #{advert.id}"
      assert log.subject_path == "/admin/adverts"
    end

    test "an undersized image is a changeset error and writes no log" do
      advert = advert_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               Adverts.update_advert_image(actor(admin_user_fixture()), "#{advert.id}", %{
                 "image" => undersized_png_upload()
               })

      refute changeset.valid?
      no_moderation_logs!()
    end

    test "a plain moderator is rejected by the module gate" do
      advert = advert_fixture()

      assert Adverts.update_advert_image(actor(moderator_user_fixture()), "#{advert.id}", %{
               "image" => png_upload()
             }) == {:error, :unauthorized}

      no_moderation_logs!()
    end

    test "an unknown id is not-found for an admin but unauthorized for an Advert-role moderator" do
      assert Adverts.update_advert_image(actor(admin_user_fixture()), "2147483647", %{
               "image" => png_upload()
             }) == {:error, :not_found}

      assert Adverts.update_advert_image(actor(role_moderator_fixture("Advert")), "2147483647", %{
               "image" => png_upload()
             }) == {:error, :unauthorized}
    end
  end

  describe "delete_advert/2" do
    test "an admin deletes an advert and writes a byte-exact log" do
      admin = admin_user_fixture()
      advert = advert_fixture()

      assert {:ok, deleted} = Adverts.delete_advert(actor(admin), "#{advert.id}")
      assert deleted.id == advert.id
      assert Repo.get(Advert, advert.id) == nil

      assert [log] = moderation_logs()
      assert log.user_id == admin.id
      assert log.type == "Admin.Advert:delete"
      assert log.body == "Deleted advert #{advert.id}"
      assert log.subject_path == "/admin/adverts"
    end

    test "a plain moderator is rejected by the module gate and writes no log" do
      advert = advert_fixture()

      assert Adverts.delete_advert(actor(moderator_user_fixture()), "#{advert.id}") ==
               {:error, :unauthorized}

      assert Repo.get(Advert, advert.id).id == advert.id
      no_moderation_logs!()
    end

    test "a non-castable id is not-found" do
      assert Adverts.delete_advert(actor(admin_user_fixture()), "abc") == {:error, :not_found}
    end

    test "an unknown id is not-found for an admin but unauthorized for an Advert-role moderator" do
      assert Adverts.delete_advert(actor(admin_user_fixture()), "2147483647") ==
               {:error, :not_found}

      assert Adverts.delete_advert(actor(role_moderator_fixture("Advert")), "2147483647") ==
               {:error, :unauthorized}
    end
  end
end
