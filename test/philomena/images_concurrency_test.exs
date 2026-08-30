defmodule Philomena.ImagesConcurrencyTest do
  use Philomena.ConcurrentDataCase

  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo
  alias Philomena.SourceChanges.SourceChange
  alias Philomena.TagChanges.TagChange
  alias Philomena.Tags.Tag

  import Philomena.AttributionFixtures
  import Philomena.ImagesFixtures
  import Philomena.TagsFixtures
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

  test "concurrent source additions merge against the locked image" do
    image = image_fixture(tags: "safe")
    actors = for _ <- 1..2, do: actor(admin_user_fixture())
    sources = ["https://example.com/concurrent-one", "https://example.com/concurrent-two"]

    results =
      concurrently(
        Enum.zip(actors, sources)
        |> Enum.map(fn {actor, source} ->
          fn -> Images.update_sources(actor, image.id, source_attrs(source)) end
        end)
      )

    assert Enum.all?(results, &match?({:ok, %{added: [_]}}, &1))
    assert source_urls(image) == Enum.sort(sources)

    assert Repo.aggregate(
             from(change in SourceChange, where: change.image_id == ^image.id),
             :count
           ) == 2
  end

  test "concurrent source updates are limited per actor" do
    user = confirmed_user_fixture()
    images = for _ <- 1..3, do: image_fixture(tags: "safe")
    actor = actor(user)

    results =
      concurrently(
        for {image, source} <-
              Enum.zip(images, [
                "https://example.com/limited-one",
                "https://example.com/limited-two",
                "https://example.com/limited-three"
              ]) do
          fn -> Images.update_sources(actor, image.id, source_attrs(source)) end
        end
      )

    assert Enum.count(results, &match?({:ok, %{added: [_]}}, &1)) == 2
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 1
  end

  test "concurrent tag additions merge against the locked image and update counts" do
    image = image_fixture(tags: "safe, initial one, initial two")
    actors = for _ <- 1..2, do: actor(admin_user_fixture())
    added_names = [unique_tag_name(), unique_tag_name()]
    old_input = "safe, initial one, initial two"

    results =
      concurrently(
        Enum.zip(actors, added_names)
        |> Enum.map(fn {actor, tag_name} ->
          fn ->
            Images.update_tags(
              actor,
              image.id,
              %{
                "old_tag_input" => old_input,
                "tag_input" => "#{old_input}, #{tag_name}"
              }
            )
          end
        end)
      )

    assert Enum.all?(results, &match?({:ok, %{added: [_]}}, &1))
    assert tag_names(image) == Enum.sort(["safe", "initial one", "initial two" | added_names])

    added_tags = Repo.all(from(tag in Tag, where: tag.name in ^added_names))

    assert Enum.map(added_tags, & &1.images_count) |> Enum.sort() == [1, 1]

    assert Repo.aggregate(
             from(change in TagChange, where: change.image_id == ^image.id),
             :count
           ) == 2
  end

  test "concurrent tag updates are limited per actor" do
    user = confirmed_user_fixture()

    images = for _ <- 1..3, do: image_fixture(tags: "safe, initial one, initial two")

    actor = actor(user)
    tag_names = for _ <- 1..3, do: unique_tag_name()
    old_input = "safe, initial one, initial two"

    results =
      concurrently(
        for {image, tag_name} <- Enum.zip(images, tag_names) do
          fn ->
            Images.update_tags(
              actor,
              image.id,
              %{
                "old_tag_input" => old_input,
                "tag_input" => "#{old_input}, #{tag_name}"
              }
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, %{added: [_]}}, &1)) == 2
    assert Enum.count(results, &(&1 == {:error, :rate_limited})) == 1
  end

  test "concurrent tag additions resolve an alias and its implications once" do
    image = image_fixture(tags: "safe, initial one, initial two")
    actors = for _ <- 1..2, do: actor(admin_user_fixture())
    alias_tag = tag_fixture(name: unique_tag_name())
    canonical_tag = tag_fixture(name: unique_tag_name())
    implied_tag = tag_fixture(name: unique_tag_name())

    canonical_tag =
      canonical_tag
      |> Repo.preload(:implied_tags)
      |> change()
      |> put_assoc(:implied_tags, [implied_tag])
      |> Repo.update!()

    alias_tag =
      alias_tag
      |> change(aliased_tag_id: canonical_tag.id)
      |> Repo.update!()

    old_input = "safe, initial one, initial two"

    results =
      concurrently(
        for actor <- actors do
          fn ->
            Images.update_tags(
              actor,
              image.id,
              %{
                "old_tag_input" => old_input,
                "tag_input" => "#{old_input}, #{alias_tag.name}"
              }
            )
          end
        end
      )

    assert Enum.count(results, &match?({:ok, %{added: [_ | _]}}, &1)) == 1
    assert Enum.count(results, &match?({:ok, %{added: [], removed: []}}, &1)) == 1

    assert tag_names(image) ==
             Enum.sort([
               "safe",
               "initial one",
               "initial two",
               canonical_tag.name,
               implied_tag.name
             ])

    assert Repo.aggregate(from(change in TagChange, where: change.image_id == ^image.id), :count) ==
             1
  end

  defp source_attrs(source) do
    %{"old_sources" => %{}, "sources" => %{"0" => %{"source" => source}}}
  end

  defp source_urls(image) do
    image
    |> Repo.preload(:sources, force: true)
    |> Map.fetch!(:sources)
    |> Enum.map(& &1.source)
    |> Enum.sort()
  end

  defp tag_names(image) do
    image
    |> Repo.preload(:tags, force: true)
    |> Map.fetch!(:tags)
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end
end
