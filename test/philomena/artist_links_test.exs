defmodule Philomena.ArtistLinksTest do
  @moduledoc """
  Context-level tests for the actor-first artist-link loaders and writers on
  `Philomena.ArtistLinks`.

  These pin the two-layer authorization the link routes preserve: the raw
  `ArtistLink` action (`:show`/`:edit`/`:update`) on the loaded link, followed
  by the mapped `:create_links`/`:edit_links` action on the profile `User`. The
  owner/unrelated/staff matrix is exercised against each layer, including the
  asymmetry where a profile owner may create and view their own links but not
  edit them.
  """

  use Philomena.DataCase, async: true

  import Philomena.AttributionFixtures
  import Philomena.ArtistLinksFixtures
  import Philomena.TagsFixtures
  import Philomena.UsersFixtures

  alias Philomena.ArtistLinks
  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.Repo

  # A truthy ban value in the shape production passes; only its presence matters
  # to the write-access and not-banned checks the loaders run first.
  @ban %{
    reason: "Rule #0",
    valid_until: ~U[3000-01-01 00:00:00Z],
    generated_ban_id: "U123456",
    type: "User"
  }

  defp artist_tag_fixture do
    tag_fixture(name: "artist:test-link-artist-#{System.unique_integer([:positive])}")
  end

  # Link params in the shape the artist-link form posts.
  defp link_params(attrs \\ %{}) do
    Enum.into(attrs, %{
      "tag_name" => artist_tag_fixture().name,
      "uri" => "https://example.com/gallery-#{System.unique_integer([:positive])}"
    })
  end

  describe "list_artist_links/2" do
    test "the profile owner lists their own links" do
      user = confirmed_user_fixture()
      link = artist_link_fixture(user, artist_tag_fixture())

      assert {:ok, {loaded_user, links}} = ArtistLinks.list_artist_links(user, user.slug)
      assert loaded_user.id == user.id
      assert Enum.map(links, & &1.id) == [link.id]
    end

    test "a moderator lists another user's links" do
      user = confirmed_user_fixture()
      link = artist_link_fixture(user, artist_tag_fixture())

      assert {:ok, {_user, links}} =
               ArtistLinks.list_artist_links(moderator_user_fixture(), user.slug)

      assert Enum.map(links, & &1.id) == [link.id]
    end

    test "an unrelated user may not list another user's links" do
      user = confirmed_user_fixture()

      assert ArtistLinks.list_artist_links(confirmed_user_fixture(), user.slug) ==
               {:error, :unauthorized}
    end

    test "an anonymous viewer may not list links" do
      assert ArtistLinks.list_artist_links(nil, confirmed_user_fixture().slug) ==
               {:error, :unauthorized}
    end

    test "an unknown slug is unauthorized for an unrelated user, not-found for an admin" do
      assert ArtistLinks.list_artist_links(confirmed_user_fixture(), "no-such-user") ==
               {:error, :unauthorized}

      assert ArtistLinks.list_artist_links(admin_user_fixture(), "no-such-user") ==
               {:error, :not_found}
    end
  end

  describe "load_artist_link_for_new/2" do
    test "the profile owner gets a changeset" do
      user = confirmed_user_fixture()

      assert {:ok, {loaded_user, %Ecto.Changeset{data: %ArtistLink{}}}} =
               ArtistLinks.load_artist_link_for_new(actor(user), user.slug)

      assert loaded_user.id == user.id
    end

    test "a banned actor is rejected before any authorization" do
      user = confirmed_user_fixture()

      assert ArtistLinks.load_artist_link_for_new(actor(user, ban: @ban), user.slug) ==
               {:error, :ban}
    end

    test "an unrelated user may not open another user's new form" do
      user = confirmed_user_fixture()

      assert ArtistLinks.load_artist_link_for_new(actor(confirmed_user_fixture()), user.slug) ==
               {:error, :unauthorized}
    end
  end

  describe "create_artist_link/3" do
    test "the profile owner inserts an unverified link" do
      user = confirmed_user_fixture()

      assert {:ok, {loaded_user, %ArtistLink{} = link}} =
               ArtistLinks.create_artist_link(actor(user), user.slug, link_params())

      assert loaded_user.id == user.id
      assert Repo.get(ArtistLink, link.id).user_id == user.id
      assert link.aasm_state == "unverified"
    end

    test "an actor with no fingerprint is unauthorized" do
      user = confirmed_user_fixture()

      assert ArtistLinks.create_artist_link(
               actor(user, fingerprint: nil),
               user.slug,
               link_params()
             ) == {:error, :unauthorized}
    end

    test "an unrelated user may not create a link on another profile" do
      user = confirmed_user_fixture()

      assert ArtistLinks.create_artist_link(
               actor(confirmed_user_fixture()),
               user.slug,
               link_params()
             ) == {:error, :unauthorized}
    end
  end

  describe "load_artist_link_for_show/3" do
    test "the profile owner views their own link" do
      user = confirmed_user_fixture()
      link = artist_link_fixture(user, artist_tag_fixture())

      assert {:ok, {loaded_user, loaded_link}} =
               ArtistLinks.load_artist_link_for_show(user, user.slug, "#{link.id}")

      assert loaded_user.id == user.id
      assert loaded_link.id == link.id
    end

    test "a moderator views another user's link" do
      user = confirmed_user_fixture()
      link = artist_link_fixture(user, artist_tag_fixture())

      assert {:ok, {_user, loaded_link}} =
               ArtistLinks.load_artist_link_for_show(
                 moderator_user_fixture(),
                 user.slug,
                 "#{link.id}"
               )

      assert loaded_link.id == link.id
    end

    test "a non-castable id is not-found" do
      user = confirmed_user_fixture()

      assert ArtistLinks.load_artist_link_for_show(user, user.slug, "abc") == {:error, :not_found}
    end
  end

  describe "load_artist_link_for_edit/3" do
    test "a moderator loads the edit form" do
      user = confirmed_user_fixture()
      link = artist_link_fixture(user, artist_tag_fixture())

      assert {:ok, {loaded_link, %Ecto.Changeset{}}} =
               ArtistLinks.load_artist_link_for_edit(
                 moderator_user_fixture(),
                 user.slug,
                 "#{link.id}"
               )

      assert loaded_link.id == link.id
    end

    test "the profile owner may not edit their own link" do
      # Owners get :create_links and :show on their own links, but neither :edit
      # on the link nor :edit_links on the profile, so editing is refused.
      user = confirmed_user_fixture()
      link = artist_link_fixture(user, artist_tag_fixture())

      assert ArtistLinks.load_artist_link_for_edit(user, user.slug, "#{link.id}") ==
               {:error, :unauthorized}
    end

    test "a non-castable id is not-found" do
      user = confirmed_user_fixture()

      assert ArtistLinks.load_artist_link_for_edit(moderator_user_fixture(), user.slug, "abc") ==
               {:error, :not_found}
    end
  end

  describe "update_artist_link/4" do
    test "a moderator updates a link" do
      user = confirmed_user_fixture()
      tag = artist_tag_fixture()
      link = artist_link_fixture(user, tag)

      # The edit path resolves the tag by name, so the form always carries a
      # "tag_name"; omitting it crashes in Tags.get_tag_or_alias_by_name/1.
      assert {:ok, {loaded_user, updated}} =
               ArtistLinks.update_artist_link(
                 moderator_user_fixture(),
                 user.slug,
                 "#{link.id}",
                 %{"tag_name" => tag.name, "uri" => "https://example.com/updated-gallery"}
               )

      assert loaded_user.id == user.id
      assert updated.uri == "https://example.com/updated-gallery"
      assert Repo.get(ArtistLink, link.id).uri == "https://example.com/updated-gallery"
    end

    test "the profile owner may not update their own link" do
      user = confirmed_user_fixture()
      link = artist_link_fixture(user, artist_tag_fixture())

      assert ArtistLinks.update_artist_link(
               user,
               user.slug,
               "#{link.id}",
               %{"uri" => "https://example.com/updated-gallery"}
             ) == {:error, :unauthorized}
    end
  end
end
