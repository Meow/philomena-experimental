defmodule Philomena.Activities do
  @moduledoc """
  The site homepage: the recent, top-scoring, watched, featured, comment,
  stream, and topic strips it assembles for a viewer.
  """

  import Ecto.Query, only: [preload: 2]
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Activities.FrontPage
  alias Philomena.Attribution.Actor
  alias Philomena.Channels
  alias Philomena.Comments
  alias Philomena.Comments.Comment
  alias Philomena.Filters.Filter
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Interactions
  alias Philomena.Topics
  alias PhilomenaQuery.Search

  @strip_pagination %{page_number: 1, page_size: 6}

  @type load_result :: {:ok, FrontPage.t()} | {:error, :unauthorized | String.t()}

  defp search_definitions(%Actor{} = actor, %Scope{} = scope, %Filter{} = filter) do
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

    with {:ok, watched_definition} <- watched_definition(actor, scope) do
      {:ok, {images_definition, top_scoring_definition, comments_definition, watched_definition}}
    end
  end

  defp watched_definition(%Actor{user: nil}, _scope), do: {:ok, nil}

  defp watched_definition(%Actor{}, scope) do
    with {:ok, {definition, _tags}} <-
           ImageSearch.search_string(scope, "my:watched",
             pagination: %{scope.pagination | page_number: 1}
           ) do
      {:ok, definition}
    end
  end

  defp load_search_sections({images, top_scoring, comments, watched}) do
    [images, top_scoring, comments, watched] =
      multi_search(images, top_scoring, comments, watched)

    %{images: images, top_scoring: top_scoring, comments: comments, watched: watched}
  end

  defp load_featured_image(actor, scope) do
    include_hidden? = scope.params["hidden"] == "1"

    case Images.featured_image(actor, include_hidden?) do
      {:ok, image} -> image
      {:error, :not_found} -> nil
    end
  end

  defp load_streams(actor, show_nsfw_channels?) do
    {page, _subscriptions} =
      Channels.load_channels(actor, show_nsfw_channels?, %{}, @strip_pagination)

    page.entries
  end

  defp assemble_front_page(actor, scope, definitions, show_nsfw_channels?) do
    sections = load_search_sections(definitions)
    featured_image = load_featured_image(actor, scope)
    streams = load_streams(actor, show_nsfw_channels?)
    topics = Topics.list_front_page_topics(actor)

    interactions =
      Interactions.user_interactions(actor, [
        sections.images,
        sections.top_scoring,
        sections.watched,
        featured_image
      ])

    %FrontPage{
      images: sections.images,
      top_scoring: sections.top_scoring,
      comments: sections.comments,
      watched: sections.watched,
      featured_image: featured_image,
      streams: streams,
      topics: topics,
      interactions: interactions
    }
  end

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

  @doc """
  Assembles the homepage for `actor` using the image-search state in `scope`.

  Actor is the sole authority source: any `scope.user` supplied by the caller is
  replaced with `actor.user`; the scope otherwise retains compiled filter,
  pagination, and display parameters. `filter` supplies hidden tags for the
  recent-comment strip, and `show_nsfw_channels?` controls the channel strip.

  The four OpenSearch strips execute as one multi-search. Anonymous actors have
  no watched strip (`nil`); authenticated actors receive a page, including an
  empty page when no watched tags match. Featured-image, channel, and topic
  visibility delegate to their owning contexts. No section failure is converted
  into an empty section: compiler errors are returned and OpenSearch failures
  fail the whole request.

  ## Examples

      iex> load_front_page(anonymous_actor, scope, filter, false)
      {:ok, %FrontPage{watched: nil}}

      iex> load_front_page(actor, scope, filter, true)
      {:ok, %FrontPage{watched: %Scrivener.Page{}}}

  """
  @spec load_front_page(Actor.t(), Scope.t(), Filter.t(), boolean()) :: load_result()
  def load_front_page(
        %Actor{} = actor,
        %Scope{} = scope,
        %Filter{} = filter,
        show_nsfw_channels?
      )
      when is_boolean(show_nsfw_channels?) do
    scope = %{scope | user: actor.user}

    with :ok <- authorize(actor, :index, FrontPage),
         {:ok, definitions} <- search_definitions(actor, scope, filter) do
      {:ok, assemble_front_page(actor, scope, definitions, show_nsfw_channels?)}
    end
  end
end
