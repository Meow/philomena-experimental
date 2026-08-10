defmodule Philomena.Activities do
  @moduledoc """
  The site homepage: the recent, top-scoring, watched, featured, comment,
  stream, and topic strips it assembles for a viewer.
  """

  import Ecto.Query

  alias Philomena.Activities.FrontPage
  alias Philomena.Attribution.Actor
  alias Philomena.Channels.Channel
  alias Philomena.Comments
  alias Philomena.Comments.Comment
  alias Philomena.Filters.Filter
  alias Philomena.Forums.Forum
  alias Philomena.ImageFeatures.ImageFeature
  alias Philomena.Images.Image
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Interactions
  alias Philomena.Repo
  alias Philomena.Topics.Topic
  alias PhilomenaQuery.Search

  @doc """
  Assembles the homepage for the viewer described by `scope`.

  `filter` is the viewer's active `Filter` (its hidden tags exclude comments);
  `show_nsfw_channels?` reflects whether the viewer wants NSFW channels shown.
  The recent, top-scoring, comment, and watched strips are batched into a single
  multi-search; the featured image, streams, and topics are loaded from
  Postgres. Anonymous viewers have no watched strip (`nil`). The featured
  image and the recent listing honour the scope's `hidden` setting.

  Returns a `FrontPage` struct carrying the viewer's interactions across the
  image collections.

  ## Examples

      iex> load_front_page(scope, filter, false)
      %FrontPage{}

  """
  @spec load_front_page(Actor.t(), Scope.t(), Filter.t(), boolean()) :: FrontPage.t()
  def load_front_page(%Actor{} = actor, %Scope{} = scope, %Filter{} = filter, show_nsfw_channels?) do
    user = actor.user

    {images_definition, _tags} =
      ImageSearch.default_query(scope, pagination: %{scope.pagination | page_number: 1})

    {top_scoring_definition, _tags} =
      ImageSearch.query(
        scope,
        %{range: %{first_seen_at: %{gt: "now-3d"}}},
        sorts: &%{query: &1, sorts: [%{wilson_score: :desc}, %{first_seen_at: :desc}]},
        pagination: %{page_number: :rand.uniform(6), page_size: 4}
      )

    comments_definition =
      Comments.comment_search_definition(
        actor,
        filter,
        %{range: %{created_at: %{gt: "now-1w"}}},
        pagination: %{page_number: 1, page_size: 6},
        show_hidden: false
      )

    watched_definition =
      if user do
        {:ok, {definition, _tags}} =
          ImageSearch.search_string(scope, "my:watched",
            pagination: %{scope.pagination | page_number: 1}
          )

        definition
      end

    [images, top_scoring, comments, watched] =
      multi_search(
        images_definition,
        top_scoring_definition,
        comments_definition,
        watched_definition
      )

    featured_image =
      Image
      |> join(:inner, [i], f in ImageFeature, on: [image_id: i.id])
      |> where([i], i.hidden_from_users == false)
      |> filter_hidden(user, scope.params["hidden"])
      |> order_by([i, f], desc: f.created_at)
      |> limit(1)
      |> preload([:sources, tags: :aliases])
      |> Repo.one()

    streams =
      Channel
      |> where([c], not is_nil(c.last_fetched_at))
      |> maybe_show_nsfw_channels(show_nsfw_channels?)
      |> order_by(desc: :is_live, asc: :title)
      |> limit(6)
      |> Repo.all()

    topics =
      Topic
      |> join(:inner, [t], f in Forum, on: [id: t.forum_id])
      |> where([t, _f], t.hidden_from_users == false)
      |> where([t, _f], fragment("? !~ ?", t.title, "NSFW"))
      |> where([_t, f], f.access_level == "normal")
      |> order_by(desc: :last_replied_to_at)
      |> preload([:forum, last_post: :user])
      |> limit(6)
      |> Repo.all()

    interactions =
      Interactions.user_interactions(actor, [images, top_scoring, watched, featured_image])

    %FrontPage{
      images: images,
      top_scoring: top_scoring,
      comments: comments,
      watched: watched,
      featured_image: featured_image,
      streams: streams,
      topics: topics,
      interactions: interactions
    }
  end

  defp filter_hidden(featured_image, nil, _hidden) do
    featured_image
  end

  defp filter_hidden(featured_image, _user, "1") do
    featured_image
  end

  defp filter_hidden(featured_image, user, _hidden) do
    featured_image
    |> where(
      [i],
      fragment(
        "NOT EXISTS(SELECT 1 FROM image_hides WHERE image_id = ? AND user_id = ?)",
        i.id,
        ^user.id
      )
    )
  end

  defp maybe_show_nsfw_channels(query, true), do: query
  defp maybe_show_nsfw_channels(query, _false), do: where(query, [c], c.nsfw == false)

  defp multi_search(images, top_scoring, comments, nil) do
    responses =
      Search.msearch_records(
        [images, top_scoring, comments],
        [
          preload(Image, [:sources, tags: :aliases]),
          preload(Image, [:sources, tags: :aliases]),
          preload(Comment, [:user, image: [:sources, tags: :aliases]])
        ]
      )

    responses ++ [nil]
  end

  defp multi_search(images, top_scoring, comments, watched) do
    Search.msearch_records(
      [images, top_scoring, comments, watched],
      [
        preload(Image, [:sources, tags: :aliases]),
        preload(Image, [:sources, tags: :aliases]),
        preload(Comment, [:user, image: [:sources, tags: :aliases]]),
        preload(Image, [:sources, tags: :aliases])
      ]
    )
  end
end
