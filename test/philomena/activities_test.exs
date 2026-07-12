defmodule Philomena.ActivitiesTest do
  @moduledoc """
  Context-level tests for `Philomena.Activities.load_front_page/3`, which
  assembles the homepage strips for a viewer.

  The recent, top-scoring, comment, and watched strips run against the real
  OpenSearch indexes; the featured image, streams, and topics load from
  Postgres.
  """

  use Philomena.DataCase, async: false

  @moduletag :search

  import Philomena.ChannelsFixtures
  import Philomena.CommentsFixtures
  import Philomena.ForumsFixtures
  import Philomena.ImagesFixtures
  import Philomena.TopicsFixtures
  import Philomena.UsersFixtures

  alias Philomena.Activities
  alias Philomena.Activities.FrontPage
  alias Philomena.Channels.Channel
  alias Philomena.Comments.Comment
  alias Philomena.Filters.Filter
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Images.Search.Scope
  alias PhilomenaQuery.Search
  alias PhilomenaQuery.SearchHelpers

  setup do
    Search.clear_index!(Image)
    Search.clear_index!(Comment)
    :ok
  end

  # The compiled filter body the web layer produces for a viewer with no active
  # filter: an empty tag_ids exclusion plus a pair of match_none clauses, so it
  # excludes nothing.
  defp default_filter do
    %{
      bool: %{
        should: [
          %{terms: %{tag_ids: []}},
          %{bool: %{should: [%{match_none: %{}}, %{match_none: %{}}]}}
        ]
      }
    }
  end

  defp scope(user \\ nil) do
    %Scope{user: user, filter: default_filter()}
  end

  # The %Filter{} the web layer passes as the comment-strip filter; only its
  # hidden_tag_ids are read.
  defp filter, do: %Filter{hidden_tag_ids: []}

  defp hours_ago(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
    |> DateTime.truncate(:second)
  end

  # A live channel needs a fetch time to appear at all; the front page filters
  # on last_fetched_at. create_channel casts only the type and short name, so
  # the fetch time and nsfw flag are set directly on the row.
  defp live_channel(fields) do
    channel_fixture(%{})
    |> Ecto.Changeset.change(Enum.into(fields, %{last_fetched_at: hours_ago(1)}))
    |> Repo.update!()
  end

  describe "load_front_page/3 for an anonymous scope" do
    test "returns a FrontPage struct with every key populated" do
      image = image_fixture(created_at: hours_ago(1))
      comment = comment_fixture(image, confirmed_user_fixture())
      topic = topic_fixture(forum_fixture())

      SearchHelpers.reindex_all!(Image)
      SearchHelpers.reindex_all!(Comment)

      front = Activities.load_front_page(scope(), filter(), false)

      assert %FrontPage{} = front

      assert %Scrivener.Page{} = front.images
      assert image.id in Enum.map(front.images.entries, & &1.id)

      assert %Scrivener.Page{} = front.top_scoring

      assert %Scrivener.Page{} = front.comments
      assert comment.id in Enum.map(front.comments.entries, & &1.id)

      # Anonymous viewers have no watched strip.
      assert front.watched == nil

      # No feature and no channels on a fresh site.
      assert front.featured_image == nil
      assert front.streams == []

      assert Enum.any?(front.topics, &(&1.id == topic.id))
      assert is_list(front.interactions)
    end

    test "the recent listing preloads each image's tags" do
      image = image_fixture(created_at: hours_ago(1))
      SearchHelpers.reindex_all!(Image)

      front = Activities.load_front_page(scope(), filter(), false)

      entry = Enum.find(front.images.entries, &(&1.id == image.id))
      assert Ecto.assoc_loaded?(entry.tags)
    end

    test "the featured image is set when an image feature exists" do
      image = image_fixture(created_at: hours_ago(1))
      {:ok, _feature} = Images.feature_loaded_image(confirmed_user_fixture(), image)

      SearchHelpers.reindex_all!(Image)

      front = Activities.load_front_page(scope(), filter(), false)

      assert front.featured_image.id == image.id
    end
  end

  describe "load_front_page/3 for a signed-in scope" do
    test "the watched strip is a page rather than nil" do
      user = confirmed_user_fixture()

      front = Activities.load_front_page(scope(user), filter(), false)

      assert %Scrivener.Page{} = front.watched
      assert is_list(front.watched.entries)
    end
  end

  describe "load_front_page/3 stream strip" do
    test "a channel with a fetch time appears in the streams" do
      channel = live_channel(%{})

      front = Activities.load_front_page(scope(), filter(), false)

      assert Enum.any?(front.streams, &(&1.id == channel.id))
    end

    test "a channel without a fetch time never appears" do
      channel = channel_fixture(%{})
      assert channel.last_fetched_at == nil

      front = Activities.load_front_page(scope(), filter(), false)

      refute Enum.any?(front.streams, &(&1.id == channel.id))
    end

    test "an nsfw channel is hidden when nsfw channels are off" do
      channel = live_channel(%{nsfw: true})

      front = Activities.load_front_page(scope(), filter(), false)

      refute Enum.any?(front.streams, &(&1.id == channel.id))
    end

    test "an nsfw channel appears when nsfw channels are on" do
      channel = live_channel(%{nsfw: true})

      front = Activities.load_front_page(scope(), filter(), true)

      assert Enum.any?(front.streams, &(&1.id == channel.id))
    end

    test "a safe channel appears regardless of the nsfw switch" do
      channel = live_channel(%{nsfw: false})

      assert %Channel{} = channel
      front = Activities.load_front_page(scope(), filter(), false)

      assert Enum.any?(front.streams, &(&1.id == channel.id))
    end
  end
end
