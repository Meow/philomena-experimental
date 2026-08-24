defmodule Philomena.TagWorkersTest do
  use Philomena.DataCase, async: false
  use Patch

  import Philomena.AttributionFixtures
  import Philomena.ImagesFixtures
  import Philomena.ArtistLinksFixtures
  import Philomena.TagsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Repo
  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.TagAliasWorker
  alias Philomena.TagDeleteWorker
  alias Philomena.TagReindexWorker
  alias Philomena.Tags.Tag
  alias Philomena.TagUnaliasWorker
  alias Philomena.Tags
  alias PhilomenaQuery.Search

  defp tag_ids(image) do
    image
    |> Repo.preload(:tags, force: true)
    |> Map.fetch!(:tags)
    |> Enum.map(& &1.id)
  end

  test "the alias worker moves image taggings to the target tag" do
    source = tag_fixture(name: "worker alias source")
    target = tag_fixture(name: "worker alias target")
    image = image_fixture(tags: "safe, #{source.name}")

    source
    |> Ecto.Changeset.change(aliased_tag_id: target.id)
    |> Repo.update!()

    assert :ok = TagAliasWorker.perform(source.id, target.id)

    ids = tag_ids(image)
    assert target.id in ids
    refute source.id in ids
    assert Repo.reload!(source).aliased_tag_id == target.id
  end

  test "the alias worker moves visible image counts from source to target" do
    source = tag_fixture(name: "worker visible count source")
    target = tag_fixture(name: "worker visible count target")
    _image = image_fixture(tags: source.name)

    source = source |> Ecto.Changeset.change(images_count: 1) |> Repo.update!()
    target = target |> Ecto.Changeset.change(images_count: 0) |> Repo.update!()

    source
    |> Ecto.Changeset.change(aliased_tag_id: target.id)
    |> Repo.update!()

    assert :ok = TagAliasWorker.perform(source.id, target.id)

    assert Repo.reload!(source).images_count == 0
    assert Repo.reload!(target).images_count == 1
  end

  test "the alias worker does not count hidden images when moving taggings" do
    source = tag_fixture(name: "worker hidden count source")
    target = tag_fixture(name: "worker hidden count target")
    _image = image_fixture(tags: source.name, hidden_from_users: true)

    source = source |> Ecto.Changeset.change(images_count: 0) |> Repo.update!()
    target = target |> Ecto.Changeset.change(images_count: 0) |> Repo.update!()

    source
    |> Ecto.Changeset.change(aliased_tag_id: target.id)
    |> Repo.update!()

    assert :ok = TagAliasWorker.perform(source.id, target.id)

    assert Repo.reload!(source).images_count == 0
    assert Repo.reload!(target).images_count == 0
  end

  test "aliasing deletes conflicting artist links before the worker runs" do
    admin = admin_user_fixture()
    user = confirmed_user_fixture()
    source = tag_fixture(name: "artist:worker alias source")
    target = tag_fixture(name: "artist:worker alias target")
    uri = "https://example.com/artist"

    source_link = artist_link_fixture(user, source, %{"uri" => uri})
    target_link = artist_link_fixture(user, target, %{"uri" => uri})

    assert {:ok, _tag} =
             Tags.alias_tag(
               actor(admin),
               source.slug,
               %{"target_tag" => target.name}
             )

    refute Repo.get(ArtistLink, source_link.id)
    assert Repo.get!(ArtistLink, target_link.id).tag_id == target.id
    assert Repo.reload!(source).aliased_tag_id == target.id
  end

  test "the unalias worker removes the alias relationship" do
    target = tag_fixture(name: "worker unalias target")

    source =
      tag_fixture(name: "worker unalias source")
      |> Ecto.Changeset.change(aliased_tag_id: target.id)
      |> Repo.update!()

    assert {:ok, %Tag{id: source_id}} = TagUnaliasWorker.perform(source.id)
    assert source_id == source.id
    assert Repo.reload!(source).aliased_tag_id == nil
  end

  test "the delete worker removes the tag and its image taggings" do
    patch(Search, :delete_document, :ok)
    patch(Search, :reindex, :ok)

    tag = tag_fixture(name: "worker delete tag")
    image = image_fixture(tags: "safe, #{tag.name}")

    assert :ok = TagDeleteWorker.perform(tag.id)

    assert Repo.get(Tag, tag.id) == nil
    refute tag.id in tag_ids(image)
  end

  test "the tag reindex worker recounts visible images" do
    patch(Search, :reindex, :ok)

    tag = tag_fixture(name: "worker recount tag")
    _visible = image_fixture(tags: "safe, #{tag.name}")
    _hidden = image_fixture(tags: "safe, #{tag.name}", hidden_from_users: true)

    tag
    |> Ecto.Changeset.change(images_count: 99)
    |> Repo.update!()

    assert :ok = TagReindexWorker.perform(tag.id)
    assert Repo.reload!(tag).images_count == 1
  end
end
