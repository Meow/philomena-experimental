defmodule Philomena.TagsConcurrencyTest do
  use Philomena.ConcurrentDataCase

  import Philomena.TagsFixtures

  alias Philomena.Repo
  alias Philomena.Tags
  alias Philomena.Tags.Tag

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
end
