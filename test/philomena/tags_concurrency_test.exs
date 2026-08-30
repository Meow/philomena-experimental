defmodule Philomena.TagsConcurrencyTest do
  use Philomena.ConcurrentDataCase

  import Philomena.TagsFixtures

  alias Philomena.Images
  alias Philomena.Multi
  alias Philomena.Repo
  alias Philomena.Tags
  alias Philomena.Tags.Tag

  import Philomena.AttributionFixtures
  import Philomena.ImagesFixtures
  import Philomena.UsersFixtures

  test "overlapping vectorized counter updates complete in primary-key lock order" do
    tags = Enum.map(1..4, fn index -> tag_fixture(name: "counter tag #{index}") end)
    ascending_ids = Enum.map(tags, & &1.id)
    descending_ids = Enum.reverse(ascending_ids)

    results =
      concurrently(
        for tag_ids <- List.duplicate(ascending_ids, 4) ++ List.duplicate(descending_ids, 4) do
          fn ->
            Repo.transaction(fn ->
              Tags.update_image_counts(Repo, 1, tag_ids)
            end)
          end
        end
      )

    assert Enum.all?(results, &(&1 == {:ok, length(tags)}))

    counts =
      Tag
      |> where([tag], tag.id in ^ascending_ids)
      |> order_by(:id)
      |> select([tag], tag.images_count)
      |> Repo.all()

    assert counts == List.duplicate(length(results), length(tags))
  end

  test "concurrent canonicalization creates one tag and returns it to every transaction" do
    name = unique_tag_name()

    results =
      concurrently(
        for _ <- 1..8 do
          fn ->
            Multi.new()
            |> Tags.put_canonicalize_tag_name_sets([
              {:tags, [name], allow_insert_new?: true}
            ])
            |> Multi.transact()
          end
        end
      )

    assert Enum.all?(results, &match?({:ok, %{canonical_tags: %{tags: [%Tag{name: ^name}]}}}, &1))
    assert Repo.aggregate(from(tag in Tag, where: tag.name == ^name), :count) == 1
  end

  test "concurrent alias workers migrate each image tagging once" do
    source = tag_fixture(name: unique_tag_name())
    target = tag_fixture(name: unique_tag_name())
    images = for _ <- 1..4, do: image_fixture(tags: "safe, #{source.name}")

    source =
      source
      |> Ecto.Changeset.change(aliased_tag_id: target.id, images_count: length(images))
      |> Repo.update!()

    results =
      concurrently(
        for _ <- 1..4 do
          fn -> Tags.perform_alias(source.id, target.id) end
        end
      )

    assert results == List.duplicate(:ok, 4)

    for image <- images do
      tag_ids =
        image
        |> Repo.preload(:tags, force: true)
        |> Map.fetch!(:tags)
        |> Enum.map(& &1.id)

      assert target.id in tag_ids
      refute source.id in tag_ids
    end

    assert Repo.reload!(source).images_count == 0
    assert Repo.reload!(target).images_count == length(images)
  end

  test "an alias worker and an image tag edit serialize on the image row" do
    source = tag_fixture(name: unique_tag_name())
    target = tag_fixture(name: unique_tag_name())
    added = unique_tag_name()
    image = image_fixture(tags: "safe, #{source.name}")

    source =
      source
      |> Ecto.Changeset.change(aliased_tag_id: target.id, images_count: 1)
      |> Repo.update!()

    results =
      concurrently([
        fn -> Tags.perform_alias(source.id, target.id) end,
        fn ->
          Images.update_tags(
            actor(admin_user_fixture()),
            image.id,
            %{
              "old_tag_input" => "safe, #{source.name}",
              "tag_input" => "safe, #{source.name}, #{added}"
            }
          )
        end
      ])

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:ok, %{added: [%Tag{}]}}, &1)) == 1

    tag_ids =
      image
      |> Repo.preload(:tags, force: true)
      |> Map.fetch!(:tags)
      |> Enum.map(& &1.id)

    assert target.id in tag_ids
    refute source.id in tag_ids
    assert Enum.any?(Repo.preload(image, :tags, force: true).tags, &(&1.name == added))
    assert Repo.reload!(source).images_count == 0
    assert Repo.reload!(target).images_count == 1
  end

  test "an alias worker and a batch tag edit serialize on the image row" do
    source = tag_fixture(name: unique_tag_name())
    target = tag_fixture(name: unique_tag_name())
    image = image_fixture(tags: "safe, #{source.name}")

    source =
      source
      |> Ecto.Changeset.change(aliased_tag_id: target.id, images_count: 1)
      |> Repo.update!()

    results =
      concurrently([
        fn -> Tags.perform_alias(source.id, target.id) end,
        fn -> Images.batch_update_tags(actor(admin_user_fixture()), source.name, [image.id]) end
      ])

    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &match?({:ok, %{added: [_ | _]}}, &1)) == 1

    tag_ids =
      image
      |> Repo.preload(:tags, force: true)
      |> Map.fetch!(:tags)
      |> Enum.map(& &1.id)

    assert target.id in tag_ids
    refute source.id in tag_ids
    assert Repo.reload!(source).images_count == 0
    assert Repo.reload!(target).images_count == 1
  end
end
