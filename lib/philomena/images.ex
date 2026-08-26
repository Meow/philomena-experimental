defmodule Philomena.Images do
  @moduledoc """
  Image browsing, uploads, metadata, moderation, interactions, and indexing.

  Request-facing operations accept an actor and load image locators before
  authorizing the requested action. Worker and cross-context services are
  named separately from that controller boundary.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  require Logger

  alias Philomena.Multi
  alias Philomena.Repo

  alias PhilomenaQuery.Search
  alias Philomena.ThumbnailWorker
  alias Philomena.ImagePurgeWorker
  alias Philomena.DuplicateReports.DuplicateReport
  alias Philomena.Images.Image
  alias Philomena.Images.Filtering
  alias Philomena.Images.Uploader
  alias Philomena.Images.Tagging
  alias Philomena.Images.Thumbnailer
  alias Philomena.Images.Source
  alias Philomena.Images
  alias Philomena.IntegerId
  alias Philomena.IndexWorker
  alias Philomena.Loader
  alias Philomena.RateLimiter
  alias Philomena.Attribution.Actor
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.ImageFeatures.ImageFeature
  alias Philomena.ImageVotes
  alias Philomena.ImageHides
  alias Philomena.ImageFaves
  alias Philomena.SourceChanges
  alias Philomena.SourceChanges.SourceChange
  alias Philomena.Notifications.ImageCommentNotification
  alias Philomena.Notifications.ImageMergeNotification
  alias Philomena.TagChanges
  alias Philomena.TagChanges.TagChange
  alias Philomena.TagChanges.Limits
  alias Philomena.Tags
  alias Philomena.UserStatistics
  alias Philomena.Tags.Tag
  alias Philomena.Notifications
  alias Philomena.Interactions
  alias Philomena.Reports
  alias Philomena.Comments
  alias Philomena.Galleries
  alias Philomena.Galleries.Gallery
  alias Philomena.Galleries.Interaction
  alias Philomena.Images.ImagePage
  alias Philomena.Images.Query, as: ImageQuery
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Users.User
  alias PhilomenaWeb.Api.Json.ImageView
  alias PhilomenaWeb.Endpoint

  use Philomena.Subscriptions,
    on_delete: :clear_image_notification,
    id_name: :image_id

  defp load_image_member(%Actor{} = actor, action, image_id, preloads \\ []) do
    Loader.fetch_and_authorize(Image, actor, action, image_id, preloads)
  end

  defp maybe_exclude_viewer_hides(query, %Actor{user: nil}, _include_hidden?), do: query
  defp maybe_exclude_viewer_hides(query, %Actor{}, true), do: query

  defp maybe_exclude_viewer_hides(query, %Actor{user: user}, false) do
    where(
      query,
      [image],
      fragment(
        "NOT EXISTS(SELECT 1 FROM image_hides WHERE image_id = ? AND user_id = ?)",
        image.id,
        ^user.id
      )
    )
  end

  @doc """
  Loads the most recent featured image visible to `actor`.

  Hidden images are always excluded. When `include_hidden?` is false, an
  authenticated actor's personally hidden images are also excluded. The next
  eligible historical feature is returned when the newest one is excluded.

  ## Examples

      iex> featured_image(actor, false)
      {:ok, %Image{}}

      iex> featured_image(actor, false)
      {:error, :not_found}

  """
  @spec featured_image(Actor.t(), boolean()) :: {:ok, Image.t()} | {:error, :not_found}
  def featured_image(%Actor{} = actor, include_hidden?) when is_boolean(include_hidden?) do
    with :ok <- authorize(actor, :index, Image) do
      Image
      |> maybe_exclude_viewer_hides(actor, include_hidden?)
      |> join(:inner, [i], f in ImageFeature, on: [image_id: i.id])
      |> where([i], i.hidden_from_users == false)
      |> order_by([_i, f], desc: f.created_at)
      |> limit(1)
      |> preload([:user, :intensity, :sources, tags: :aliases])
      |> Repo.one()
      |> case do
        nil ->
          {:error, :not_found}

        image ->
          {:ok, image}
      end
    end
  end

  defp broadcast_image_create(image) do
    Endpoint.broadcast!(
      "firehose",
      "image:create",
      ImageView.render("show.json", %{image: image, interactions: []})
    )
  end

  defp broadcast_image_update(image) do
    Endpoint.broadcast!(
      "firehose",
      "image:update",
      ImageView.render("show.json", %{image: image, interactions: []})
    )
  end

  defp broadcast_description_update(image, old_description) do
    Endpoint.broadcast!(
      "firehose",
      "image:description_update",
      %{image_id: image.id, added: image.description, removed: old_description}
    )

    broadcast_image_update(image)
  end

  defp broadcast_source_update(image, added, removed) do
    Endpoint.broadcast!(
      "firehose",
      "image:source_update",
      %{image_id: image.id, added: [added], removed: [removed]}
    )

    broadcast_image_update(image)
  end

  defp broadcast_tag_update(image, added, removed) do
    Endpoint.broadcast!(
      "firehose",
      "image:tag_update",
      %{
        image_id: image.id,
        added: Enum.map(added, & &1.name),
        removed: Enum.map(removed, & &1.name)
      }
    )

    broadcast_image_update(image)
  end

  defp broadcast_image_merge(image, duplicate_of_image) do
    Endpoint.broadcast!(
      "firehose",
      "image:merge",
      %{
        image: ImageView.render("image.json", %{image: image}),
        duplicate_of_image: ImageView.render("image.json", %{image: duplicate_of_image})
      }
    )
  end

  defp moderation_image_result({:ok, %{image: image}}), do: {:ok, image}

  defp moderation_image_result({:error, :image, %Ecto.Changeset{} = changeset, _changes}),
    do: {:error, changeset}

  defp moderation_image_result(error), do: error

  @doc """
  Adds a loaded-image merge to `multi` without transacting it.

  The caller owns authorization and must lock the two images before **merging**
  this service when their current state controls the operation. PostgreSQL
  mutations join the caller's transaction; thumbnail work, indexing, and the
  firehose broadcast run only after that transaction commits.

  TODO: read the locked images out of the multi changes map, instead of relying
  on the user to read the documentation which requires the multi to be merged
  instead of simply composed

  ## Examples

      iex> put_merge_image(multi, source_image, target_image, moderator)
      %Philomena.Multi{}

  """
  @spec put_merge_image(Multi.t(), Image.t(), Image.t(), User.t()) :: Multi.t()
  def put_merge_image(
        %Multi{} = multi,
        %Image{} = image,
        %Image{} = duplicate_of_image,
        %User{} = user
      ) do
    image =
      Repo.preload(image, [:user, :intensity, :sources, tags: :aliases])

    duplicate_of_image =
      Repo.preload(duplicate_of_image, [:user, :intensity, :sources, tags: :aliases])

    source_changeset =
      Image.merge_source_changeset(image, duplicate_of_image)

    target_changeset =
      Image.merge_target_changeset(image, duplicate_of_image)

    multi
    |> put_hide_image(source_changeset, image, user)
    |> migrate_gallery_interactions_multi(image, duplicate_of_image)
    |> Multi.update(:target_image, target_changeset)
    |> Tags.put_copy_tags(image, duplicate_of_image)
    |> Multi.run(:migrate_sources, fn _, %{} ->
      {:ok, migrate_sources(image, duplicate_of_image)}
    end)
    |> Multi.run(:migrate_comments, fn _, %{} ->
      {:ok, Comments.migrate_comments(image, duplicate_of_image)}
    end)
    |> Multi.run(:migrate_subscriptions, fn _, %{} ->
      {:ok, migrate_subscriptions(image, duplicate_of_image)}
    end)
    |> Interactions.migrate_loaded_images(image, duplicate_of_image)
    |> Multi.run(:notification, &notify_merge(&1, &2, image, duplicate_of_image))
    |> put_process_after_hide()
    |> Multi.on_commit(fn result ->
      # TODO: these aren't ordered steps and some could be separate post-commit hooks
      # to emulate the pipeline style
      reindex_image(duplicate_of_image)
      Comments.reindex_comments_on_image(duplicate_of_image)
      reindex_merged_galleries(result)
      broadcast_image_merge(result.image, duplicate_of_image)
    end)
  end

  defp put_hide_image(multi, changeset, image, user) do
    multi
    |> Multi.update(:image, changeset)
    |> Reports.put_close_reports(:reports, user, image_id: image.id)
    |> Multi.run(:tags, fn repo, %{image: image} ->
      image = Repo.preload(image, :tags, force: true)

      tag_ids = Enum.map(image.tags, & &1.id)

      Tags.update_image_counts(repo, -1, tag_ids)

      {:ok, image.tags}
    end)
  end

  defp remove_gallery_interactions_multi(multi, image) do
    # Image hides hold the image lock before reaching this step. Gallery
    # membership mutations hold the same image lock first; deleting the
    # interaction rows therefore composes safely with those workflows.
    galleries =
      Gallery
      |> join(:inner, [g], gi in assoc(g, :interactions), on: gi.image_id == ^image.id)
      |> update(inc: [image_count: -1])
      |> select([g], g.id)

    gallery_interactions = where(Interaction, image_id: ^image.id)

    multi
    |> Multi.update_all(:galleries, galleries, [])
    |> Multi.delete_all(:gallery_interactions, gallery_interactions, [])
  end

  defp migrate_gallery_interactions_multi(multi, image, duplicate_of_image) do
    # Image merges hold both image locks before reaching this step. The
    # interaction updates and deletes stay in the image merge transaction; a
    # concurrent gallery deletion may lose the lock race and abort, which
    # rolls back the complete merge atomically.
    target_gallery_ids =
      Interaction
      |> where(image_id: ^duplicate_of_image.id)
      |> select([gi], gi.gallery_id)

    # Galleries may contain at most one interaction per image, so the source
    # image's interaction can only be repointed at the target image in
    # galleries which do not already contain the target.
    migratable =
      Interaction
      |> where(image_id: ^image.id)
      |> where([gi], gi.gallery_id not in subquery(target_gallery_ids))
      |> update(set: [image_id: ^duplicate_of_image.id])
      |> select([gi], gi.gallery_id)

    leftover = Interaction |> where(image_id: ^image.id) |> select([gi], gi.gallery_id)

    multi
    |> Multi.update_all(:migrated_gallery_interactions, migratable, [])
    |> Multi.delete_all(:gallery_interactions, leftover, [])
    |> Multi.run(:galleries, fn repo, %{gallery_interactions: {_count, gallery_ids}} ->
      {count, nil} =
        Gallery
        |> where([g], g.id in ^gallery_ids)
        |> repo.update_all(inc: [image_count: -1])

      {:ok, {count, gallery_ids}}
    end)
  end

  defp put_process_after_hide(multi) do
    Multi.on_commit(multi, fn %{image: image, tags: tags, galleries: {_, gallery_ids}} ->
      spawn(fn ->
        Thumbnailer.hide_thumbnails(image, image.hidden_image_key)
        purge_files(image, image.hidden_image_key)
      end)

      Comments.reindex_comments_on_image(image)
      Tags.reindex_tags(tags)
      Galleries.reindex_galleries(gallery_ids)
      reindex_image(image)
    end)
  end

  defp reindex_merged_galleries(%{
         migrated_gallery_interactions: {_, migrated_gallery_ids},
         galleries: {_, removed_gallery_ids}
       }) do
    Galleries.reindex_galleries(Enum.uniq(migrated_gallery_ids ++ removed_gallery_ids))
  end

  defp update_loaded_sources(%Image{} = image, %Actor{} = actor, attrs) do
    old_sources = attrs["old_sources"]
    new_sources = attrs["sources"]

    Multi.new()
    |> Multi.run(:image, fn repo, _chg ->
      image = repo.preload(image, [:sources])

      image
      |> Image.source_changeset(%{}, old_sources, new_sources)
      |> repo.update()
      |> case do
        {:ok, image} ->
          {:ok, {image, image.added_sources, image.removed_sources}}

        error ->
          error
      end
    end)
    |> Multi.run(:added_source_changes, fn repo, %{image: {image, added_sources, _removed}} ->
      source_changes =
        added_sources
        |> Enum.map(&source_change_attributes(actor, image, &1, true))

      {count, nil} = repo.insert_all(SourceChange, source_changes)

      {:ok, count}
    end)
    |> Multi.run(:removed_source_changes, fn repo, %{image: {image, _added, removed_sources}} ->
      source_changes =
        removed_sources
        |> Enum.map(&source_change_attributes(actor, image, &1, false))

      {count, nil} = repo.insert_all(SourceChange, source_changes)

      {:ok, count}
    end)
    |> Multi.transact()
  end

  defp source_change_attributes(%Actor{user: user} = actor, image, source, added) do
    now = DateTime.utc_now(:second)

    user_id =
      case user do
        nil -> nil
        user -> user.id
      end

    %{
      image_id: image.id,
      source_url: source,
      user_id: user_id,
      created_at: now,
      updated_at: now,
      ip: actor.ip,
      fingerprint: actor.fingerprint,
      added: added
    }
  end

  defp update_loaded_tags(%Image{} = image, %Actor{} = actor, attrs) do
    old_tags = Tags.get_or_create_tags(attrs["old_tag_input"])
    new_tags = Tags.get_or_create_tags(attrs["tag_input"])

    Multi.new()
    |> Multi.run(:image, fn repo, _chg ->
      image = repo.preload(image, [:tags, :locked_tags])

      image
      |> Image.tag_changeset(%{}, old_tags, new_tags, image.locked_tags)
      |> repo.update()
      |> case do
        {:ok, image} ->
          {:ok, {image, image.added_tags, image.removed_tags}}

        error ->
          error
      end
    end)
    |> Multi.run(:check_limits, fn _repo, %{image: {image, _added, _removed}} ->
      check_tag_change_limits_before_commit(image, actor)
    end)
    |> TagChanges.put_tag_change(actor)
    |> Multi.run(:added_tag_count, fn
      _repo, %{image: {%{hidden_from_users: true}, _added, _removed}} ->
        {:ok, 0}

      repo, %{image: {_image, added_tags, _removed}} ->
        tag_ids = added_tags |> Enum.map(& &1.id)

        count = Tags.update_image_counts(repo, 1, tag_ids)

        {:ok, count}
    end)
    |> Multi.run(:removed_tag_count, fn
      _repo, %{image: {%{hidden_from_users: true}, _added, _removed}} ->
        {:ok, 0}

      repo, %{image: {_image, _added, removed_tags}} ->
        tag_ids = removed_tags |> Enum.map(& &1.id)

        count = Tags.update_image_counts(repo, -1, tag_ids)

        {:ok, count}
    end)
    |> Multi.transact()
    |> case do
      {:ok, %{image: {image, _added, _removed}}} = res ->
        update_tag_change_limits_after_commit(image, actor)

        res

      err ->
        err
    end
  end

  defp check_tag_change_limits_before_commit(image, %Actor{ip: ip, user: user}) do
    tag_changed_count = length(image.added_tags) + length(image.removed_tags)
    rating_changed = image.ratings_changed

    cond do
      Limits.limited_for_tag_count?(user, ip, tag_changed_count) ->
        {:error, :limit_exceeded}

      rating_changed and Limits.limited_for_rating_count?(user, ip) ->
        {:error, :limit_exceeded}

      true ->
        {:ok, 0}
    end
  end

  defp update_tag_change_limits_after_commit(image, %Actor{ip: ip, user: user}) do
    rating_changed_count = if(image.ratings_changed, do: 1, else: 0)
    tag_changed_count = length(image.added_tags) + length(image.removed_tags)

    :ok = Limits.update_tag_count_after_update(user, ip, tag_changed_count)
    :ok = Limits.update_rating_count_after_update(user, ip, rating_changed_count)
    :ok
  end

  # Migrates source URLs from one image to another.
  #
  # This function is used during image merging to combine source URLs from both images.
  # It will:
  #
  # 1. Combine sources from both images
  # 2. Remove duplicates
  # 3. Take up to 15 sources (the system limit)
  # 4. Update the target image with the combined sources
  #
  # Returns the result of updating the target image with the combined sources.
  defp migrate_sources(source, target) do
    sources =
      (source.sources ++ target.sources)
      |> Enum.map(fn s -> %Source{image_id: target.id, source: s.source} end)
      |> Enum.uniq()
      |> Enum.take(15)

    target
    |> Image.sources_changeset(sources)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking image changes.

  ## Examples

      iex> change_image(image)
      %Ecto.Changeset{source: %Image{}}

  """
  @spec change_image(Image.t()) :: Ecto.Changeset.t()
  def change_image(%Image{} = image) do
    Image.changeset(image, %{})
  end

  @doc """
  Gets the tag list for a single image.
  """
  @spec tag_list(Image.t()) :: String.t()
  def tag_list(%Image{tags: tags}) do
    tags
    |> Tag.display_order()
    |> Enum.map_join(", ", & &1.name)
  end

  @doc """
  Loads the default image listing page for the viewer's search `scope`.

  Applies the front-page upload delay, the scope's filter and visibility
  switches, and the parameter-driven sort, then runs the search. Returns the
  record page with the standard listing preloads.

  ## Examples

      iex> load_image_index(actor, scope)
      %Scrivener.Page{}

  """
  @spec load_image_index(Actor.t(), Scope.t()) :: Scrivener.Page.t()
  def load_image_index(%Actor{} = actor, scope) do
    :ok = authorize(actor, :index, Image)
    {definition, _tags} = ImageSearch.default_query(actor, scope)

    ImageSearch.execute(definition)
  end

  @doc """
  Returns the paginated approval queue for `actor`: unapproved images, oldest
  first, with the listing preloads.

  Returns `{:ok, images}` as a `m:Scrivener.Page` or `{:error, :unauthorized}`.

  ## Examples

      iex> load_approval_queue(moderator, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_approval_queue(user, pagination)
      {:error, :unauthorized}

  """
  @spec load_approval_queue(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_approval_queue(%Actor{} = actor, pagination) do
    with :ok <- authorize(actor, :approve, %Image{}) do
      images =
        Image
        |> where(approved: false)
        |> order_by(asc: :id)
        |> preload([:user, :sources, tags: [:aliases, :aliased_tag]])
        |> Repo.paginate(pagination)

      {:ok, images}
    end
  end

  @doc """
  Runs the search the scope's "q" parameter describes for `actor`.

  Compiles "q" against the viewer's filter and visibility switches and executes
  it. The raw `Tag` records the query names come back alongside the page.

  Options:

    * `:preload` - the associations loaded onto the result records; defaults
      to the standard listing preloads.
    * `:hits` - whether each entry is paired with its search hit. A custom
      sort field (anything under "sf" other than `id`/`first_seen_at`) needs
      its sort cursor, so by default the page is loaded with hits exactly
      then; pass `false` to always load records alone.

  Returns `{:ok, %{images: page, tags: tags}}`, or the compiler's
  `{:error, msg}` for a malformed query.

  ## Examples

      iex> search_images(actor, scope)
      {:ok, %{images: %Scrivener.Page{}, tags: [%Tag{}]}}

      iex> search_images(actor, bad_query_scope)
      {:error, "There was an error parsing your query."}

  """
  @spec search_images(Actor.t(), Scope.t(), Keyword.t()) ::
          {:ok, %{images: Scrivener.Page.t(), tags: [Tag.t()]}} | {:error, String.t()}
  def search_images(%Actor{} = actor, scope, opts \\ []) do
    with :ok <- authorize(actor, :index, Image),
         {:ok, {definition, tags}} <-
           ImageSearch.search_string(actor, scope, scope.q) do
      preload = Keyword.get(opts, :preload, [:sources, tags: :aliases])
      hits = Keyword.get(opts, :hits, custom_ordering?(scope))

      images = ImageSearch.execute(definition, preload: preload, hits: hits)

      {:ok, %{images: images, tags: tags}}
    end
  end

  defp custom_ordering?(%{sf: sf}) when sf not in [nil, "id", "first_seen_at"], do: true
  defp custom_ordering?(_scope), do: false

  @doc """
  Loads an image representation for the JSON API or oEmbed on behalf of
  `actor`.

  The image is loaded before `:show` authorization and carries the associations
  required by the API renderer. Missing IDs are actor-independent.

  ## Examples

      iex> load_api_image(actor, "1")
      {:ok, %Image{}}

      iex> load_api_image(actor, "missing")
      {:error, :not_found}

  """
  @spec load_api_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def load_api_image(%Actor{} = actor, image_id) do
    load_image_member(actor, :show, image_id, [:user, :intensity, :sources, tags: :aliases])
  end

  @doc """
  Runs the "my:watched" search for the viewer scope, with the watched-feed
  preloads, and returns the record page.

  ## Examples

      iex> watched_images(actor, scope)
      {:ok, %Scrivener.Page{}}

  """
  @spec watched_images(Actor.t(), Scope.t()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized | String.t()}
  def watched_images(%Actor{} = actor, scope) do
    with :ok <- authorize(actor, :index, Image),
         {:ok, {definition, _tags}} <- ImageSearch.search_string(actor, scope, "my:watched") do
      {:ok, ImageSearch.execute(definition)}
    end
  end

  @doc """
  Loads the image named by `id` for showing, on behalf of `actor`.

  The image carries its preloads plus virtual fields for these counts: distinct
  tag changes, tags touched by those changes, and source changes. The real
  image is authorized for `:show`; a forbidden hidden image returns
  `{:error, :unauthorized}`. However, an image merged into a duplicate is
  redirected for viewers not permitted to show it, returning
  `{:duplicate_of, image}` so the caller can act on `image.duplicate_id`. A
  malformed or unknown id is `{:error, :not_found}`.

  ## Examples

      iex> load_image_for_show(actor, "1")
      {:ok, %Image{tag_change_count: 2, tag_change_tag_count: 5, source_change_count: 1}}

      iex> load_image_for_show(actor, "2")
      {:duplicate_of, %Image{}}

      iex> load_image_for_show(actor, "bad")
      {:error, :not_found}

  """
  @spec load_image_for_show(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()}
          | {:duplicate_of, Image.t()}
          | {:error, :unauthorized | :not_found}
  def load_image_for_show(%Actor{} = actor, id) do
    with {:ok, image} <-
           Image
           |> from(as: :image)
           |> join(:inner_lateral, [], subquery(TagChanges.count_query()), on: true)
           |> join(:inner_lateral, [], subquery(SourceChanges.count_query()), on: true)
           |> preload([:deleter, :locked_tags, :sources, user: [awards: :badge], tags: :aliases])
           |> select([image, tag_changes, source_changes], %{
             image
             | tag_change_count: tag_changes.change_count,
               tag_change_tag_count: tag_changes.tag_count,
               source_change_count: source_changes.count
           })
           |> Loader.fetch(id) do
      case authorize(actor, :show, image) do
        :ok ->
          {:ok, image}

        {:error, :unauthorized} when not is_nil(image.duplicate_id) ->
          # NOTE: the result contains the *source* image, not the target.
          {:duplicate_of, image}

        {:error, :unauthorized} ->
          {:error, :unauthorized}
      end
    end
  end

  @doc """
  Assembles the `ImagePage` for `actor`: the visible page of comments,
  the viewer's subscription state, their galleries paired with membership of
  this image, their interactions, and changesets for each action available on
  the page.

  Clears the viewer's notification for the image as a side effect, so the
  caller must read any notification counts afterwards. `comment_pagination`
  is the `page`/`page_size` keyword list. Viewers who read oldest-first and
  prefer jumping to the newest comments land on the last page unless they
  asked for a specific one. Interaction controls and comment changesets are
  omitted when the actor is banned, lacks write access, the image is hidden or
  forced-filtered, or the corresponding action is forbidden. Moderation
  changesets follow their own action authorization so authorized staff can
  still render management controls for hidden images.

  ## Examples

      iex> load_image_page(actor, image, page: 1, page_size: 25)
      %ImagePage{}

  """
  @spec load_image_page(Actor.t(), Image.t(), Repo.pagination_params()) :: ImagePage.t()
  def load_image_page(%Actor{user: user} = actor, %Image{} = image, comment_pagination) do
    clear_image_notification(image, user)

    comment_pagination = maybe_jump_to_last_page(actor, image, comment_pagination)
    {:ok, gallery_choices} = Galleries.gallery_choices_for_image(actor, image)

    can_interact = image_interaction_allowed?(actor, image)

    %ImagePage{
      image: image,
      comments: Comments.paginate_image_comments(actor, image, comment_pagination),
      watching: subscribed?(image, user),
      can_interact: can_interact,
      user_galleries: gallery_choices,
      interactions: Interactions.user_interactions(actor, [image]),
      comment_changeset: comment_changeset_for(actor, image),
      description_changeset: image_changeset_for(actor, image, :edit_description),
      tag_changeset: image_changeset_for(actor, image, :edit_metadata),
      source_changeset: image_changeset_for(actor, image, :edit_metadata),
      file_changeset: image_changeset_for(actor, image, :replace_file),
      hide_changeset: image_changeset_for(actor, image, :hide),
      feature_changeset: image_changeset_for(actor, image, :feature),
      repair_changeset: image_changeset_for(actor, image, :repair),
      hash_changeset: image_changeset_for(actor, image, :remove_hash),
      uploader_changeset: uploader_changeset_for(actor, image)
    }
  end

  defp image_interaction_allowed?(%Actor{user: nil}, _image), do: false
  defp image_interaction_allowed?(_actor, %Image{hidden_from_users: true}), do: false

  defp image_interaction_allowed?(actor, image) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :vote, image),
         :ok <- Filtering.verify_not_forced(actor, image) do
      true
    else
      _error -> false
    end
  end

  defp comment_changeset_for(_actor, %Image{hidden_from_users: true}), do: nil

  defp comment_changeset_for(actor, image) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create_comment, image),
         :ok <- Filtering.verify_not_forced(actor, image) do
      Comments.new_comment_changeset()
    else
      _error -> nil
    end
  end

  defp image_changeset_for(actor, image, action) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, action, image),
         :ok <- Filtering.verify_not_forced(actor, image) do
      change_image(%{image | sources: sources_for_edit(image.sources)})
    else
      _error -> nil
    end
  end

  defp uploader_changeset_for(actor, image) do
    case authorize(actor, :show, :identity_metadata) do
      :ok ->
        image_changeset_for(actor, image, :update_uploader)

      _error ->
        nil
    end
  end

  defp maybe_jump_to_last_page(
         %Actor{
           user: %{
             settings: %{comments_newest_first: false, comments_always_jump_to_last: true}
           }
         } = actor,
         image,
         scrivener
       ) do
    Keyword.merge(scrivener, page: Comments.last_comment_page(actor, image, scrivener))
  end

  defp maybe_jump_to_last_page(_actor, _image, scrivener), do: scrivener

  defp sources_for_edit([]), do: [%Source{}]
  defp sources_for_edit(sources), do: sources

  @doc """
  Builds the changeset for a new image upload, on behalf of `actor`.

  A banned actor is rejected with `{:error, :ban}`; everyone else gets the
  changeset.

  ## Examples

      iex> load_new_image(actor)
      {:ok, %Ecto.Changeset{}}

      iex> load_new_image(banned_actor)
      {:error, :ban}

  """
  @spec load_new_image(Actor.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized}
  def load_new_image(%Actor{} = actor) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, Image) do
      {:ok, change_image(%Image{sources: [%Source{}]})}
    end
  end

  @image_create_window 5

  @doc """
  Uploads a new image on behalf of `actor`, who must pass the write-access
  check: banned actors get `{:error, :ban}` and actors without a fingerprint
  `{:error, :unauthorized}`. A non-exempt actor who has uploaded within the last
  5 seconds gets `{:error, :rate_limited}`.

  Upon success, the image row has been created and processing continues in the
  background. Approved uploads increment the uploader's image count and may
  create a verification report in the same transaction.

  ## Examples

      iex> upload_image(actor, %{"image" => upload, "tag_input" => "safe"})
      {:ok, %{image: %Image{}, upload_pid: pid}}

      iex> upload_image(banned_actor, params)
      {:error, :ban}

  """
  @spec upload_image(Actor.t(), map() | nil) ::
          {:ok, image_upload()}
          | {:error, :ban | :unauthorized | :rate_limited | Ecto.Changeset.t()}
  def upload_image(%Actor{user: user} = actor, params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Image),
         :ok <- RateLimiter.check_rate_limit(actor, :image_create) do
      tags = Tags.get_or_create_tags(params["tag_input"])
      sources = params["sources"]

      image =
        %Image{}
        |> Image.creation_changeset(params, actor)
        |> Image.source_changeset(params, [], sources)
        |> Image.tag_changeset(params, [], tags)
        |> Image.dnp_changeset(user)
        |> Uploader.analyze_upload(params)
        |> maybe_approve_image(user)

      Multi.new()
      |> Multi.insert(:image, image)
      |> Multi.run(:added_tag_count, fn repo, %{image: image} ->
        tag_ids = Enum.map(image.added_tags, & &1.id)
        count = Tags.update_image_counts(repo, 1, tag_ids)

        {:ok, count}
      end)
      |> maybe_subscribe_on(:image, user, :watch_on_upload)
      |> put_approval_steps()
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> case do
        {:ok, %{image: %Image{} = image}} ->
          RateLimiter.record_action(actor, :image_create, @image_create_window)

          upload_pid = async_upload(image, params["image"])

          # FIXME: put_reindex_tags
          Tags.reindex_tags(image.added_tags)

          image = Repo.preload(image, tags: :aliases)

          broadcast_image_create(image)

          # Return the upload PID along with the created image so that the caller
          # can control the lifecycle of the upload if needed. It's useful, for
          # example for the seeding process to know when to delete the temp file
          # used for uploading.
          {:ok, %{image: image, upload_pid: upload_pid}}

        {:error, :image, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @typedoc """
  Result of the `upload_image/2` function. The image was created in the DB but an
  upload process could still be running in the background with its PID given in the
  `upload_pid` field.
  """
  @type image_upload :: %{
          image: %Image{},
          upload_pid: pid
        }

  defp async_upload(image, plug_upload) do
    linked_pid =
      spawn(fn ->
        # Make sure task will finish before VM exit
        Process.flag(:trap_exit, true)

        # Wait to be freed up by the caller
        receive do
          :ready -> nil
        end

        # Start trying to upload
        try_upload(image, 0)
      end)

    # Give the upload to the linked process
    Plug.Upload.give_away(plug_upload, linked_pid, self())

    # Free up the linked process
    send(linked_pid, :ready)

    linked_pid
  end

  defp try_upload(image, retry_count) when retry_count < 100 do
    try do
      Uploader.persist_upload(image)
      repair_image(image)
    rescue
      e ->
        Logger.error("Upload failed: #{inspect(e)} [try ##{retry_count}]")
        Process.sleep(5000)
        try_upload(image, retry_count + 1)
    end
  end

  defp try_upload(image, retry_count) do
    Logger.error("Aborting upload of #{image.id} after #{retry_count} retries")
  end

  defp maybe_approve_image(changeset, nil), do: changeset

  defp maybe_approve_image(changeset, %User{verified: false, role: "user"}), do: changeset

  defp maybe_approve_image(changeset, _user) do
    Image.approve_changeset(changeset)
  end

  defp put_approval_steps(%Multi{} = multi) do
    multi
    |> UserStatistics.put_increment(
      fn %{image: image} ->
        if image.approved, do: image.user_id
      end,
      :images_count
    )
    |> Multi.merge(fn
      %{image: %{approved: true, user_id: user_id}} when user_id != nil ->
        put_suggest_user_verification(Multi.new(), user_id)

      _changes ->
        Multi.new()
    end)
  end

  defp put_suggest_user_verification(%Multi{} = multi, user_id) do
    multi
    |> Multi.one(:verification_candidate, where(User, id: ^user_id))
    |> Multi.merge(fn
      %{verification_candidate: %{images_count: 5, verified: false}} ->
        # TODO: verification occurs at exactly 5 images to prevent subsequent
        # approved uploads from generating redundant user verification reports.
        # This may result in some users not receiving verification reports.
        # It would be better to check to see if the verification report has
        # been created instead and then create it if it has not been
        Reports.put_create_system_report(
          Multi.new(),
          "Verification",
          "User has uploaded enough approved images to be considered for verification.",
          :reported_user_id,
          user_id
        )

      _changes ->
        Multi.new()
    end)
  end

  @doc """
  Finds the image adjacent to the one `image_id` names in the listing the
  scope's parameters describe, for prev/next navigation, on behalf of
  `actor`.

  The image locator is parsed and loaded before `:show` authorization, so both
  malformed and unknown ids are `{:error, :not_found}`. The scope's "q"
  parameter (blank means everything) is compiled for the viewer; malformed
  queries return the parser error instead of navigating an unfiltered result.

  Returns `{:ok, {image, {adjacent, hit}}}`, where the hit carries the sort cursor
  for the caller to reuse, or `{:ok, {image, nil}}` at the end of the sequence.

  ## Examples

      iex> find_consecutive_image(actor, scope, "42")
      {:ok, {%Image{}, {%Image{}, %{"sort" => [...]}}}}

  """
  @spec find_consecutive_image(Actor.t(), Scope.t(), IntegerId.integer_id()) ::
          {:ok, {Image.t(), {Image.t(), map()} | nil}}
          | {:error, :unauthorized | :not_found}
  def find_consecutive_image(%Actor{} = actor, scope, image_id) do
    with {:ok, image} <- load_image_for_navigation(actor, image_id),
         {:ok, query} <- navigation_query(actor, scope) do
      {:ok, {image, ImageSearch.find_consecutive(actor, scope, image, query)}}
    end
  end

  defp navigation_query(actor, scope) do
    # TODO: probably should make this its own form
    scope.q
    |> match_all_if_blank()
    |> ImageQuery.compile(user: actor.user)
  end

  defp match_all_if_blank(nil), do: "*"

  defp match_all_if_blank(input) do
    if String.trim(input) == "" do
      "*"
    else
      input
    end
  end

  @doc """
  Returns the 1-based page number on which the image `image_id`
  names appears when all images are listed by descending id, on behalf of
  `actor`.

  Loading and authorization follow `find_consecutive_image/3`.

  ## Examples

      iex> find_image_index_page(actor, scope, "42")
      {:ok, 3}

  """
  @spec find_image_index_page(Actor.t(), Scope.t(), IntegerId.integer_id()) ::
          {:ok, pos_integer()} | {:error, :unauthorized | :not_found}
  def find_image_index_page(%Actor{} = actor, scope, image_id) do
    with {:ok, image} <- load_image_for_navigation(actor, image_id) do
      pagination = %{scope.pagination | page_number: 1}

      {definition, _tags} =
        ImageSearch.query(actor, scope, %{range: %{id: %{gt: image.id}}}, pagination: pagination)

      images = ImageSearch.execute(definition, preload: [])

      {:ok, div(images.total_entries, pagination.page_size) + 1}
    end
  end

  @doc """
  Loads images related to the one `image_id` names. Related images share its
  lowest-population tags, weighted towards its most distinctive ones and the
  favers it has in common.

  Loading and authorization follow `find_consecutive_image/3`; the image
  carries the faves, sources, and tags the scoring reads.

  Returns `{:ok, {image, images}}` with the related images scored best-first.

  ## Examples

      iex> related_images(actor, scope, "42")
      {:ok, {%Image{}, %Scrivener.Page{}}}

  """
  @spec related_images(Actor.t(), Scope.t(), IntegerId.integer_id()) ::
          {:ok, {Image.t(), Scrivener.Page.t()}} | {:error, :unauthorized | :not_found}
  def related_images(%Actor{} = actor, scope, image_id) do
    with {:ok, image} <-
           load_image_for_navigation(actor, image_id, [:faves, :sources, tags: :aliases]) do
      tags_to_match =
        image.tags
        |> Enum.reject(&(&1.category == "rating"))
        |> Enum.sort_by(& &1.images_count)
        |> Enum.take(10)
        |> Enum.map(& &1.id)

      low_count_tags =
        tags_to_match
        |> Enum.take(5)
        |> Enum.map(&%{term: %{tag_ids: &1}})

      high_count_tags =
        tags_to_match
        |> Enum.take(-5)
        |> Enum.map(&%{term: %{tag_ids: &1}})

      favs_to_match =
        image.faves
        |> Enum.take(11)
        |> Enum.map(&%{term: %{favourited_by_user_ids: &1.user_id}})

      query = %{
        bool: %{
          must: [
            %{bool: %{should: low_count_tags, boost: 2}},
            %{bool: %{should: high_count_tags, boost: 3, minimum_should_match: "5%"}},
            %{bool: %{should: favs_to_match, boost: 0.2, minimum_should_match: "5%"}}
          ],
          must_not: %{term: %{id: image.id}}
        }
      }

      {definition, _tags} =
        ImageSearch.query(
          actor,
          scope,
          query,
          sorts: &%{query: &1, sorts: [%{_score: :desc}]},
          pagination: %{scope.pagination | page_number: 1}
        )

      {:ok, {image, ImageSearch.execute(definition)}}
    end
  end

  @doc """
  Picks a random image id from the listing the scope's "q" parameter
  describes (everything when absent), respecting the scope's filter and
  visibility switches.

  Returns `{:ok, id}` or `{:ok, nil}` when nothing matches. A malformed query
  returns `{:error, parser_message}`.

  ## Examples

      iex> random_image_id(actor, scope)
      {:ok, 42}

  """
  @spec random_image_id(Actor.t(), Scope.t()) ::
          {:ok, integer() | nil} | {:error, :unauthorized | String.t()}
  def random_image_id(%Actor{} = actor, scope) do
    with :ok <- authorize(actor, :index, Image),
         {:ok, {definition, _tags}} <-
           ImageSearch.search_string(
             actor,
             scope,
             scope.q || "*",
             pagination: %{page_size: 1},
             sorts: &ImageSearch.parse_sort(%{"sf" => "random"}, &1)
           ) do
      definition
      |> ImageSearch.execute(preload: [])
      |> Enum.to_list()
      |> case do
        [image] ->
          {:ok, image.id}

        [] ->
          {:ok, nil}
      end
    end
  end

  defp load_image_for_navigation(actor, image_id, preloads \\ []) do
    load_image_member(actor, :show, image_id, preloads)
  end

  @doc """
  Loads the image named by `image_id`, applying `preloads`, and authorizes
  `actor` for `:show` on it.

  Returns `{:ok, image}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> load_visible_image(actor, "1")
      {:ok, %Image{}}

      iex> load_visible_image(actor, "999999999")
      {:error, :not_found}

  """
  @spec load_visible_image(Actor.t(), IntegerId.integer_id(), list()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def load_visible_image(actor, image_id, preloads \\ []) do
    load_image_member(actor, :show, image_id, preloads)
  end

  @doc """
  Loads an image as a report target on behalf of `actor`.

  The image is authorized for `:show` and carries the sources and tag aliases
  rendered by the shared report form. Missing IDs are always not-found.

  ## Examples

      iex> load_report_target(actor, "1")
      {:ok, %Image{}}
  """
  @spec load_report_target(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def load_report_target(%Actor{} = actor, image_id) do
    load_image_member(actor, :show, image_id, [:sources, tags: :aliases])
  end

  @doc """
  Reverts one loaded image source change during account erasure.

  The erasure workflow supplies its system attribution and owns target
  selection; this service records the compensating source-history rows in the
  same form as an ordinary source update, without request rate limiting.

  ## Examples

      iex> revert_source_change_for_erasure(image, system_actor, attrs)
      {:ok, %{image: {%Image{}, added, removed}}}

  """
  @spec revert_source_change_for_erasure(Image.t(), Actor.t(), map()) ::
          {:ok, map()} | Multi.failure()
  def revert_source_change_for_erasure(%Image{} = image, %Actor{} = actor, attrs) do
    update_loaded_sources(image, actor, attrs)
  end

  @doc """
  Approves the image named by `image_id` for public viewing, on behalf of
  `actor`.

  An image that is already approved returns an error changeset and is left
  untouched. On success the image is made visible, statistics are updated, the
  image is reindexed, and a moderation log is written attributing the approval
  to `actor`. Approval at the uploader's fifth approved image also creates a
  verification report in the same transaction.

  Returns `{:ok, image}` with the approved image.

  ## Examples

      iex> approve_image(moderator, "42")
      {:ok, %Image{}}

      iex> approve_image(user, "42")
      {:error, :unauthorized}

  """
  @spec approve_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def approve_image(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :approve, image_id) do
      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.update(:image, fn %{locked_image: image} -> Image.approve_changeset(image) end)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Image.Approve:create",
        Paths.image_path(image),
        "Approved image #{image.id}"
      )
      |> put_approval_steps()
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> case do
        {:ok, %{image: %Image{} = image}} ->
          {:ok, image}

        {:error, :image, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}

        error ->
          error
      end
    end
  end

  @doc """
  Counts the number of images pending approval that a user can moderate.

  ## Examples

      iex> count_pending_approvals(admin)
      42

      iex> count_pending_approvals(user)
      nil

  """
  @spec count_pending_approvals(Actor.t()) :: non_neg_integer() | nil
  def count_pending_approvals(%Actor{} = actor) do
    if authorize(actor, :approve, %Image{}) == :ok do
      Image
      |> where(approved: false)
      |> Repo.aggregate(:count)
    else
      nil
    end
  end

  @doc """
  Loads images by ID with the associations required by rich text references.

  Unknown IDs are omitted. Results are not guaranteed to follow the input
  order; callers which need keyed access should index them by ID.

  ## Examples

      iex> list_images_by_ids([42, 999_999_999])
      [%Image{id: 42}]

  """
  @spec list_images_by_ids([integer()]) :: [Image.t()]
  def list_images_by_ids(ids) when is_list(ids) do
    Image
    |> where([image], image.id in ^ids)
    |> preload([:sources, tags: :aliases])
    |> Repo.all()
  end

  @doc """
  Returns whether `image` matches the viewer's compiled hide/spoiler policy.
  """
  @spec filter_or_spoiler_hits?(Image.t(), Philomena.Filters.ImageFilter.t()) :: boolean()
  def filter_or_spoiler_hits?(%Image{} = image, image_filter) do
    Filtering.filter_or_spoiler_hits?(image, image_filter)
  end

  @doc """
  Marks the image named by `image_id` as the current featured image, on behalf
  of `actor`.

  The image is loaded by id and authorized for `:feature`. On success the feature is
  recorded and a moderation log is written attributing it to `actor`.

  Returns `{:ok, feature}` with the created feature.

  ## Examples

      iex> feature_image(moderator, "42")
      {:ok, %ImageFeature{}}

      iex> feature_image(user, "42")
      {:error, :unauthorized}

  """
  @spec feature_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, ImageFeature.t()} | {:error, :ban | :unauthorized | :not_found}
  def feature_image(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :feature, image_id) do
      feature_changeset =
        %ImageFeature{user_id: actor.user.id, image_id: image.id}
        |> ImageFeature.changeset()

      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.insert(:feature, feature_changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Image.Feature:create",
        Paths.image_path(image),
        "Featured image #{image.id}"
      )
      |> Multi.transact()
      |> case do
        {:ok, %{feature: %ImageFeature{} = feature}} ->
          {:ok, feature}

        {:error, :feature, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Hard-deletes the contents of the image named by `image_id`, on behalf of
  `actor`, purging its stored file and thumbnails.

  The image is loaded by id and authorized for `:destroy`. Only an already-deleted
  image (hidden from users) may be destroyed; a still-visible image is
  `{:error, :not_deleted}`, left untouched. On success the file and thumbnails are
  purged and a moderation log is written attributing the destruction to `actor`.

  Returns `{:ok, image}` with the destroyed image, or
  `{:error, %Ecto.Changeset{}}` if the destruction is rejected.

  ## Examples

      iex> destroy_image(admin, "42")
      {:ok, %Image{}}

      iex> destroy_image(moderator, "42")
      {:error, :unauthorized}

  """
  @spec destroy_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()}
          | {:error, :ban | :unauthorized | :not_found | :not_deleted | Ecto.Changeset.t()}
  def destroy_image(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :destroy, image_id) do
      result =
        Multi.new()
        |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
        |> Multi.run(:state, fn
          _repo, %{locked_image: %Image{hidden_from_users: true}} -> {:ok, :deleted}
          _repo, %{locked_image: %Image{hidden_from_users: false}} -> {:error, :not_deleted}
        end)
        |> Multi.update(:image, fn %{locked_image: image} ->
          Image.remove_image_changeset(image)
        end)
        |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
          {"Image.Destroy:create", Paths.image_path(image), "Hard-deleted image #{image.id}"}
        end)
        |> put_reindex_image(:image)
        |> Multi.transact()
        |> case do
          {:ok, %{image: image}} -> {:ok, image}
          {:error, :image, changeset, _changes} -> {:error, changeset}
          {:error, :state, :not_deleted, _changes} -> {:error, :not_deleted}
          error -> error
        end

      with {:ok, image} <- result do
        purge_files(image, image.hidden_image_key)
        Thumbnailer.destroy_thumbnails(image)
        {:ok, image}
      end
    end
  end

  @doc """
  Locks (`locked?` true) or unlocks (`locked?` false) comments on the image
  named by `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:lock_comments`. On success commenting
  is toggled, the image is reindexed, and a moderation log is written attributing
  the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> set_comment_locked(moderator, "42", true)
      {:ok, %Image{}}

      iex> set_comment_locked(user, "42", true)
      {:error, :unauthorized}

  """
  @spec set_comment_locked(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def set_comment_locked(%Actor{} = actor, image_id, locked?) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :lock_comments, image_id) do
      {log_type, log_body} =
        if locked? do
          {"Image.CommentLock:create", "Locked comments on image #{image.id}"}
        else
          {"Image.CommentLock:delete", "Unlocked comments on image #{image.id}"}
        end

      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.lock_comments_changeset(image, locked?)
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {log_type, Paths.image_path(image), log_body}
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @doc """
  Locks (`locked?` true) or unlocks (`locked?` false) description editing on the
  image named by `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:lock_description`. On success description
  editing is toggled, the image is reindexed, and a moderation log is written
  attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> set_description_locked(moderator, "42", true)
      {:ok, %Image{}}

      iex> set_description_locked(user, "42", true)
      {:error, :unauthorized}

  """
  @spec set_description_locked(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def set_description_locked(%Actor{} = actor, image_id, locked?) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :lock_description, image_id) do
      {log_type, log_body} =
        if locked? do
          {"Image.DescriptionLock:create", "Locked description editing on image #{image.id}"}
        else
          {"Image.DescriptionLock:delete", "Unlocked description editing on image #{image.id}"}
        end

      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.lock_description_changeset(image, locked?)
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {log_type, Paths.image_path(image), log_body}
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @doc """
  Locks (`locked?` true) or unlocks (`locked?` false) tag editing on the image
  named by `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:lock_tags`. On success tag editing
  is toggled, the image is reindexed, and a moderation log is written attributing
  the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> set_tag_locked(moderator, "42", true)
      {:ok, %Image{}}

      iex> set_tag_locked(user, "42", true)
      {:error, :unauthorized}

  """
  @spec set_tag_locked(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def set_tag_locked(%Actor{} = actor, image_id, locked?) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :lock_tags, image_id) do
      {log_type, log_body} =
        if locked? do
          {"Image.TagLock:create", "Locked tags on image #{image.id}"}
        else
          {"Image.TagLock:delete", "Unlocked tags on image #{image.id}"}
        end

      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.lock_tags_changeset(image, locked?)
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {log_type, Paths.image_path(image), log_body}
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @doc """
  Clears the original SHA-512 hash of the image named by `image_id`, on behalf
  of `actor`, allowing the same file to be uploaded again.

  The image is loaded by id and authorized for `:remove_hash`. On success the hash is
  cleared, the image is reindexed, and a moderation log is written attributing the
  change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> remove_image_hash(moderator, "42")
      {:ok, %Image{}}

      iex> remove_image_hash(user, "42")
      {:error, :unauthorized}

  """
  @spec remove_image_hash(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def remove_image_hash(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :remove_hash, image_id) do
      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.update(:image, fn %{locked_image: image} -> Image.remove_hash_changeset(image) end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {"Image.Hash:delete", Paths.image_path(image), "Cleared hash of image #{image.id}"}
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @doc """
  Loads the image named by `image_id` for moderation, on behalf of `actor`.

  The image is loaded by id and authorized for `:hide`; the write-access gate
  is applied because callers use this loader to prepare mutations.

  Returns `{:ok, image}` with the loaded image, carrying the associations
  named by `opts[:preload]` (none by default).

  ## Examples

      iex> load_hidable_image(moderator, "42")
      {:ok, %Image{}}

      iex> load_hidable_image(user, "42")
      {:error, :unauthorized}

  """
  @spec load_hidable_image(Actor.t(), IntegerId.integer_id(), Keyword.t()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_hidable_image(%Actor{} = actor, image_id, opts \\ []) do
    with :ok <- verify_write_access(actor) do
      load_image_member(actor, :hide, image_id, Keyword.get(opts, :preload, []))
    end
  end

  @doc """
  Updates the moderation notes on the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with a `"scratchpad"` key).

  The image is loaded by id and authorized for `:edit_scratchpad`. On success the notes are
  updated, the image is reindexed, and a moderation log is written attributing the
  change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> update_scratchpad(moderator, "42", %{"scratchpad" => "watch closely"})
      {:ok, %Image{}}

      iex> update_scratchpad(user, "42", %{"scratchpad" => "watch closely"})
      {:error, :unauthorized}

  """
  @spec update_scratchpad(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def update_scratchpad(%Actor{} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :edit_scratchpad, image_id) do
      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.scratchpad_changeset(image, attrs)
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {
          "Image.Scratchpad:update",
          Paths.image_path(image),
          "Updated mod notes on image #{image.id} (#{image.scratchpad})"
        }
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @doc """
  Deletes the source change history of the image named by `image_id`, on behalf
  of `actor`.

  The image is loaded by id and authorized for `:remove_source_history`. On success the source history
  is removed, the image is reindexed, and a moderation log is written attributing
  the deletion to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> remove_source_history(moderator, "42")
      {:ok, %Image{}}

      iex> remove_source_history(user, "42")
      {:error, :unauthorized}

  """
  @spec remove_source_history(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def remove_source_history(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <-
           load_image_member(actor, :remove_source_history, image_id, [:source_changes]) do
      query = Image |> where(id: ^image.id) |> preload(:source_changes)

      Multi.new()
      |> Multi.lock_one(:locked_image, query)
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.remove_source_history_changeset(image)
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {
          "Image.SourceHistory:delete",
          Paths.image_path(image),
          "Deleted source history for image #{image.id}"
        }
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @doc """
  Repairs the image named by `image_id`, on behalf of `actor`, by regenerating
  its thumbnails and purging its cached files.

  The image is loaded by id and authorized for `:repair`. On success the thumbnail
  regeneration job is enqueued, the image's CDN files are purged, and a moderation
  log is written attributing the repair to `actor`.

  Returns `{:ok, image}` with the loaded image.

  ## Examples

      iex> repair_image(moderator, "42")
      {:ok, %Image{}}

      iex> repair_image(user, "42")
      {:error, :unauthorized}

  """
  @spec repair_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def repair_image(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :repair, image_id) do
      query = where(Image, id: ^image.id)

      Multi.new()
      |> Multi.update_all(:image_repair, query,
        set: [thumbnails_generated: false, processed: false]
      )
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Image.Repair:create",
        Paths.image_path(image),
        "Repaired image #{image.id}"
      )
      |> Multi.transact()
      |> case do
        {:ok, _changes} ->
          enqueue_image_repair(image)
          purge_files(image, image.hidden_image_key)
          {:ok, image}

        error ->
          error
      end
    end
  end

  defp repair_image(%Image{} = image) do
    Image
    |> where(id: ^image.id)
    |> Repo.update_all(set: [thumbnails_generated: false, processed: false])

    enqueue_image_repair(image)
  end

  defp enqueue_image_repair(image) do
    Exq.enqueue(Exq, queue(image.image_mime_type), ThumbnailWorker, [image.id])

    image
  end

  defp queue("video/webm"), do: "videos"
  defp queue(_mime_type), do: "images"

  @doc """
  Replaces the file content of the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with an `"image"` upload).

  The image is loaded by id and authorized for `:replace_file`. A deleted image (hidden
  from users) cannot be replaced and is `{:error, :deleted}`, left untouched.
  On success the file is replaced, thumbnails are regenerated, old files are
  purged, the image is reindexed, and a moderation log is written attributing
  the change to `actor`.

  Returns `{:ok, image}` with the updated image, or
  `{:error, %Ecto.Changeset{}}` when the replacement is rejected (e.g. no file,
  or a file already uploaded as another image), leaving the image untouched.

  ## Examples

      iex> update_file(moderator, "42", %{"image" => upload})
      {:ok, %Image{}}

      iex> update_file(user, "42", %{"image" => upload})
      {:error, :unauthorized}

  """
  @spec update_file(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()}
          | {:error, :ban | :unauthorized | :not_found | :deleted | Ecto.Changeset.t()}
  def update_file(%Actor{} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :replace_file, image_id) do
      result =
        Multi.new()
        |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
        |> Multi.run(:state, fn
          _repo, %{locked_image: %Image{hidden_from_users: false}} -> {:ok, :visible}
          _repo, %{locked_image: %Image{hidden_from_users: true}} -> {:error, :deleted}
        end)
        |> Multi.update(:image, fn %{locked_image: image} ->
          image |> Image.changeset(attrs) |> Uploader.analyze_upload(attrs)
        end)
        |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
          {"Image.File:update", Paths.image_path(image), "Updated file of image #{image.id}"}
        end)
        |> put_reindex_image(:image)
        |> Multi.transact()
        |> case do
          {:error, :state, :deleted, _changes} -> {:error, :deleted}
          result -> moderation_image_result(result)
        end

      with {:ok, image} <- result do
        Uploader.persist_upload(image)
        repair_image(image)
        purge_files(image, image.hidden_image_key)
        {:ok, image}
      end
    end
  end

  @doc """
  Updates the description of the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with a `"description"` key).

  Banned actors are rejected first with `{:error, :ban}` (a write with no
  fingerprint is `{:error, :unauthorized}`). The image is then loaded by id and
  authorized for `:edit_description`. The uploader may edit a non-hidden image
  whose description editing is allowed, and staff may edit any image.

  Returns `{:ok, {image, old_description}}` with the updated image (its author,
  sources, and tags preloaded) and the description it replaced. The context
  broadcasts the description and image updates after persistence. Returns
  `{:error, %Ecto.Changeset{}}` when the new
  description is rejected (e.g. too long), leaving the image untouched.

  ## Examples

      iex> update_description(actor, "42", %{"description" => "New description"})
      {:ok, {%Image{}, "Old description"}}

      iex> update_description(actor, "42", %{"description" => "..."})
      {:error, :unauthorized}

  """
  @spec update_description(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, {Image.t(), String.t() | nil}}
          | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_description(%Actor{} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <-
           load_image_member(actor, :edit_description, image_id, [
             :user,
             :sources,
             tags: :aliases
           ]) do
      old_description = image.description

      image
      |> Image.description_changeset(attrs)
      |> Repo.update()
      # FIXME Multi, put_reindex_image
      |> reindex_after_update()
      |> case do
        {:ok, image} ->
          broadcast_description_update(image, old_description)

          {:ok, {image, old_description}}

        error ->
          error
      end
    end
  end

  @source_update_window 5

  @doc """
  Updates the sources of the image named by `image_id`, on behalf of `actor`,
  from `attrs` (`"old_sources"`/`"sources"` maps),
  recording source change records attributed to the actor.

  Banned actors are rejected first with `{:error, :ban}` (a write with no
  fingerprint is `{:error, :unauthorized}`), before the image is loaded. A
  non-exempt actor who has updated metadata within the last 5 seconds gets
  `{:error, :rate_limited}`. The image is then loaded by id (with its author,
  sources, and tags preloaded) and authorized for `:edit_metadata`. Sources are
  editable on a non-hidden image by anyone (anonymous included). On success the
  sources are updated and attributed, the actor's metadata-update stat is
  incremented when sources actually changed, and the image is reindexed.

  Returns `{:ok, %{image: image, added: added_sources, removed: removed_sources,
  source_change_count: count}}`. The context broadcasts the source and image
  updates after persistence. Returns `{:error, %Ecto.Changeset{}}` when
  the update is rejected (e.g. more than the allowed number of sources), leaving
  the image untouched.

  ## Examples

      iex> update_sources(actor, "42", %{"old_sources" => %{}, "sources" => %{"0" => %{"source" => "http://example.com"}}})
      {:ok, %{image: %Image{}, added: ["http://example.com"], removed: [], source_change_count: 1}}

  """
  @spec update_sources(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok,
           %{
             image: Image.t(),
             added: [String.t()],
             removed: [String.t()],
             source_change_count: non_neg_integer()
           }}
          | {:error, :ban | :unauthorized | :not_found | :rate_limited | Ecto.Changeset.t()}
  def update_sources(%Actor{} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :source_update),
         {:ok, image} <-
           load_image_member(actor, :edit_metadata, image_id, [:user, :sources, tags: :aliases]),
         {:ok, %{image: {image, added, removed}}} <-
           update_loaded_sources(image, actor, attrs) do
      if Enum.any?(added) or Enum.any?(removed) do
        UserStatistics.increment(actor.user, :metadata_updates_count)
      end

      reindex_image(image)
      RateLimiter.record_action(actor, :source_update, @source_update_window)

      image = Repo.preload(image, [:user, :sources, tags: :aliases], force: true)
      broadcast_source_update(image, added, removed)

      {:ok,
       %{
         image: image,
         added: added,
         removed: removed,
         source_change_count: SourceChanges.count_for_image(image)
       }}
    else
      {:error, :ban} -> {:error, :ban}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, :rate_limited} -> {:error, :rate_limited}
      # Normalize the loaded update engine's legacy empty-result shapes.
      shape when shape in [{:error, :not_found}, :error, nil] -> {:error, :not_found}
      {:error, :image, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Updates the locked tag list of the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with a `"tag_input"` key).

  The image is loaded by id and authorized for `:lock_tags`. A blank `tag_input` clears
  the list. On success the locked tags are replaced, the image is reindexed, and a
  moderation log is written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> update_locked_tags(moderator, "42", %{"tag_input" => "safe, solo"})
      {:ok, %Image{}}

      iex> update_locked_tags(user, "42", %{"tag_input" => "safe, solo"})
      {:error, :unauthorized}

  """
  @spec update_locked_tags(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def update_locked_tags(%Actor{} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :lock_tags, image_id, [:locked_tags]) do
      new_tags = Tags.get_or_create_tags(attrs["tag_input"])

      query = Image |> where(id: ^image.id) |> preload(:locked_tags)

      Multi.new()
      |> Multi.lock_one(:locked_image, query)
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.locked_tags_changeset(image, attrs, new_tags)
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {
          "Image.TagLock:update",
          Paths.image_path(image),
          "Updated list of locked tags on image #{image.id}"
        }
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @tag_update_window 5

  @doc """
  Updates the tags of the image named by `image_id`, on behalf of `actor`, from
  `attrs` (`"old_tag_input"`/`"tag_input"`), recording tag
  change records attributed to the actor.

  Banned actors are rejected first with `{:error, :ban}` (a write with no
  fingerprint is `{:error, :unauthorized}`), before the image is loaded. A
  non-exempt actor who has updated metadata within the last 5 seconds gets
  `{:error, :rate_limited}` from the once-per-window check. The image is then
  loaded by id (with its author, locked tags, sources, and tags preloaded) and
  authorized for `:edit_metadata` - editable on a non-hidden image whose tag
  editing is allowed by anyone (anonymous included), so an image with tag editing
  disabled is `{:error, :unauthorized}`. On success the tags are updated and
  attributed, the image, its comments, and the affected tags are reindexed, and
  the actor's metadata-update stat is incremented when tags actually changed.

  On success, returns `{:ok, %{image: image, added: added_tags, removed: removed_tags,
  tag_change_count: count, tag_change_tag_count: tag_count}}`. The context
  broadcasts the tag and image updates after persistence.

  ## Failure shapes

  - `{:error, %Ecto.Changeset{}}` when the update is rejected (e.g. the
    image would drop below the minimum tag count)
  - `{:error, :update_failed}` for any other rollback
  - `{:error, :rate_limited}` from either of two independent
    counters - the once-per-window check above, or the
    in-transaction `TagChanges.Limits` check that caps the number of tag and rating
    changes over ten minutes and rolls back at the
    `:check_limits` step.

  All failures leave the image untouched.

  ## Examples

      iex> update_tags(actor, "42", %{"old_tag_input" => "safe", "tag_input" => "safe, cute"})
      {:ok, %{image: %Image{}, added: [%Tag{}], removed: [], tag_change_count: 1, tag_change_tag_count: 1}}

  """
  @spec update_tags(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok,
           %{
             image: Image.t(),
             added: [Tag.t()],
             removed: [Tag.t()],
             tag_change_count: non_neg_integer(),
             tag_change_tag_count: non_neg_integer()
           }}
          | {:error,
             :ban
             | :unauthorized
             | :not_found
             | :rate_limited
             | :update_failed
             | Ecto.Changeset.t()}
  def update_tags(%Actor{} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :tag_update),
         {:ok, image} <-
           load_image_member(actor, :edit_metadata, image_id, [
             :user,
             :locked_tags,
             :sources,
             tags: :aliases
           ]),
         {:ok, %{image: {image, added, removed}}} <-
           update_loaded_tags(image, actor, attrs) do
      Comments.reindex_comments_on_image(image)
      reindex_image(image)
      Tags.reindex_tags(added ++ removed)

      if Enum.any?(added ++ removed) do
        UserStatistics.increment(actor.user, :metadata_updates_count)
      end

      RateLimiter.record_action(actor, :tag_update, @tag_update_window)

      {tag_change_count, tag_change_tag_count} = TagChanges.count_for_image(image)
      image = Repo.preload(image, [:sources, tags: :aliases], force: true)

      broadcast_tag_update(image, added, removed)

      {:ok,
       %{
         image: image,
         added: added,
         removed: removed,
         tag_change_count: tag_change_count,
         tag_change_tag_count: tag_change_tag_count
       }}
    else
      {:error, :ban} -> {:error, :ban}
      {:error, :unauthorized} -> {:error, :unauthorized}
      # The once-per-window check, distinct from the tag-count `:check_limits`
      # rollback below.
      {:error, :rate_limited} -> {:error, :rate_limited}
      # Normalize the loaded update engine's legacy empty-result shapes.
      shape when shape in [{:error, :not_found}, :error, nil] -> {:error, :not_found}
      {:error, :image, changeset, _changes} -> {:error, changeset}
      {:error, :check_limits, _value, _changes} -> {:error, :rate_limited}
      _other -> {:error, :update_failed}
    end
  end

  @doc """
  Reassigns the uploader of the image named by `image_id`, on behalf of `actor`,
  from `image_params`.

  `image_params` is a map with a `"username"` key. A blank username clears the
  uploader, anonymizing it.

  Authorization requires both `:show` on `:identity_metadata` and
  `:update_uploader` on the loaded image. The identity capability is checked
  first; malformed and missing image ids are otherwise `{:error, :not_found}`.
  On success the uploader is reassigned, the image is
  reindexed, and a moderation log is written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image (its new uploader and their awards
  preloaded), `{:error, :invalid_params}` when `image_params` is not
  a map, or `{:error, %Ecto.Changeset{}}` when the username names no user, both
  leaving the image untouched.

  ## Examples

      iex> update_uploader(moderator, "42", %{"username" => "Admin"})
      {:ok, %Image{}}

      iex> update_uploader(user, "42", %{"username" => "Admin"})
      {:error, :unauthorized}

  """
  @spec update_uploader(Actor.t(), IntegerId.integer_id(), any()) ::
          {:ok, Image.t()}
          | {:error, :ban | :unauthorized | :not_found | :invalid_params | Ecto.Changeset.t()}
  def update_uploader(%Actor{} = actor, image_id, image_params) do
    with :ok <- authorize(actor, :show, :identity_metadata),
         :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :update_uploader, image_id),
         true <- is_map(image_params) do
      result =
        Multi.new()
        |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
        |> Multi.update(:image, fn %{locked_image: image} ->
          Image.uploader_changeset(image, image_params)
        end)
        |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
          {
            "Image.Uploader:update",
            Paths.image_path(image),
            "Changed uploader of image #{image.id}"
          }
        end)
        |> put_reindex_image(:image)
        |> Multi.transact()
        |> moderation_image_result()

      with {:ok, image} <- result do
        {:ok, Repo.preload(image, user: [awards: :badge])}
      end
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      false -> {:error, :invalid_params}
      error -> error
    end
  end

  @doc """
  Sets or clears the anonymity status of the image named by `image_id`,
  on behalf of `actor`.

  Authorization requires both `:show` on `:identity_metadata` and
  `:update_anonymous` on the loaded image. The identity capability is checked
  first; malformed and missing image ids are otherwise `{:error, :not_found}`.
  On success the anonymity is toggled, the image is
  reindexed, and a moderation log is written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> update_anonymous(moderator, "42", true)
      {:ok, %Image{}}

      iex> update_anonymous(user, "42", true)
      {:error, :unauthorized}

  """
  @spec update_anonymous(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def update_anonymous(%Actor{} = actor, image_id, anonymous?) do
    with :ok <- authorize(actor, :show, :identity_metadata),
         :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :update_anonymous, image_id) do
      log_type = if anonymous?, do: "Image.Anonymous:create", else: "Image.Anonymous:delete"

      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.anonymous_changeset(image, %{"anonymous" => anonymous?})
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {log_type, Paths.image_path(image), "Updated anonymity of image #{image.id}"}
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> moderation_image_result()
    end
  end

  @doc """
  Updates the deletion reason of the image named by `image_id`, on behalf of
  `actor`, from `attrs`.

  The image is loaded by id and authorized for `:update_hide_reason`. Only an already-hidden
  image may have its reason changed; a visible image is `{:error, :not_deleted}`,
  left untouched. On success the reason is updated, the image is reindexed, and
  a moderation log is written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image, or `{:error, %Ecto.Changeset{}}`
  when the new reason is rejected (e.g. blank), leaving the image untouched.

  ## Examples

      iex> update_hide_reason(moderator, "42", %{"deletion_reason" => "Duplicate"})
      {:ok, %Image{}}

      iex> update_hide_reason(user, "42", %{"deletion_reason" => "Duplicate"})
      {:error, :unauthorized}

  """
  @spec update_hide_reason(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()}
          | {:error, :ban | :unauthorized | :not_found | :not_deleted | Ecto.Changeset.t()}
  def update_hide_reason(%Actor{} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :update_hide_reason, image_id) do
      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.run(:state, fn
        _repo, %{locked_image: %Image{hidden_from_users: true}} -> {:ok, :deleted}
        _repo, %{locked_image: %Image{hidden_from_users: false}} -> {:error, :not_deleted}
      end)
      |> Multi.update(:image, fn %{locked_image: image} ->
        Image.hide_reason_changeset(image, attrs)
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {
          "Image.Delete:update",
          Paths.image_path(image),
          "Changed deletion reason of #{image.id} (#{image.deletion_reason})"
        }
      end)
      |> put_reindex_image(:image)
      |> Multi.transact()
      |> case do
        {:error, :state, :not_deleted, _changes} -> {:error, :not_deleted}
        result -> moderation_image_result(result)
      end
    end
  end

  defp reindex_after_update(result) do
    case result do
      {:ok, image} ->
        reindex_image(image)

        {:ok, image}

      error ->
        error
    end
  end

  @doc """
  Hides (soft-deletes) the image named by `image_id` from public view, on behalf
  of `actor`, recording the deletion reason from `attrs`.

  The image is loaded by id and authorized for `:hide`. On success the image is
  hidden (its reports and duplicate reports closed, tag counts decremented,
  thumbnails purged, everything reindexed) and a moderation log is written attributing
  the deletion to `actor`.

  Returns `{:ok, image}` with the hidden image, or `{:error, :hide_failed}` when
  the hide is rejected (e.g. a blank deletion reason), leaving the image visible.

  ## Examples

      iex> hide_image(moderator, "42", %{"deletion_reason" => "Rule violation"})
      {:ok, %Image{}}

      iex> hide_image(user, "42", %{"deletion_reason" => "Rule violation"})
      {:error, :unauthorized}

  """
  @spec hide_image(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found | :hide_failed}
  def hide_image(%Actor{user: user} = actor, image_id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :hide, image_id) do
      duplicate_reports_query =
        DuplicateReport
        |> where(state: "open")
        |> where([d], d.image_id == ^image.id or d.duplicate_of_image_id == ^image.id)
        |> update(set: [state: "rejected"])

      changeset_fun = fn %{locked_image: image} -> Image.hide_changeset(image, attrs, user) end

      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> put_hide_image(changeset_fun, image, user)
      |> remove_gallery_interactions_multi(image)
      |> Multi.update_all(:duplicate_reports, duplicate_reports_query, [])
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: hidden} ->
        {
          "Image.Delete:create",
          Paths.image_path(hidden),
          "Deleted image #{hidden.id} (#{hidden.deletion_reason})"
        }
      end)
      |> put_process_after_hide()
      |> Multi.transact()
      |> case do
        {:ok, %{image: hidden}} -> {:ok, hidden}
        {:error, _op, _changeset, _changes} -> {:error, :hide_failed}
      end
    end
  end

  @doc """
  Restores (unhides) the image named by `image_id` from moderation hiding, on
  behalf of `actor`.

  The image is loaded by id and authorized for `:unhide`. Restoring an image that
  is not hidden still succeeds (it is left visible). On success the image is
  made visible, its content reindexed, and a moderation log is written
  attributing the restore to `actor`.

  Returns `{:ok, image}` with the restored image.

  ## Examples

      iex> unhide_image(moderator, "42")
      {:ok, %Image{}}

      iex> unhide_image(user, "42")
      {:error, :unauthorized}

  """
  @spec unhide_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def unhide_image(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :unhide, image_id) do
      Multi.new()
      |> Multi.lock_one(:locked_image, where(Image, id: ^image.id))
      |> Multi.run(:restore_metadata, fn _repo, %{locked_image: image} ->
        {:ok, {image.hidden_from_users, image.hidden_image_key}}
      end)
      |> Multi.run(:image, fn repo, %{locked_image: image} ->
        # FIXME: don't allow unhiding visible images
        if image.hidden_from_users do
          repo.update(Image.unhide_changeset(image))
        else
          {:ok, image}
        end
      end)
      |> Multi.run(:tags, fn repo, %{locked_image: locked_image, image: image} ->
        if locked_image.hidden_from_users do
          image = repo.preload(image, :tags, force: true)
          tag_ids = Enum.map(image.tags, & &1.id)
          query = where(Tag, [t], t.id in ^tag_ids)

          repo.update_all(query, inc: [images_count: 1])

          {:ok, image.tags}
        else
          {:ok, []}
        end
      end)
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{image: image} ->
        {"Image.Delete:delete", Paths.image_path(image), "Restored image #{image.id}"}
      end)
      |> Multi.transact()
      |> case do
        {:ok, %{image: image, tags: tags, restore_metadata: {true, key}}} ->
          spawn(fn -> Thumbnailer.unhide_thumbnails(image, key) end)
          reindex_image(image)
          purge_files(image, key)
          Comments.reindex_comments_on_image(image)
          Tags.reindex_tags(tags)

          {:ok, image}

        {:ok, %{image: image, restore_metadata: {false, _key}}} ->
          {:ok, image}

        error ->
          error
      end
    end
  end

  @doc """
  Applies a batch tag edit to `image_ids` on behalf of `actor`.

  Authorizes `:batch_update` against the tag model, parses the tag list into the
  added and removed tags (resolving aliases and implications for additions),
  splits the raw ids into castable integers and unparsable leftovers, and runs
  the batch through `batch_update/4`. Batch tagging is a staff feature and is
  not rate-limited. Writes an `"Admin.Batch.Tag:update"` moderation log, whose
  subject is the acting user's own profile, on success.

  On success returns `{:ok, result}` where `result` is a map with:

    * `:succeeded` - ids the batch matched (existing, non-hidden images);
    * `:failed` - ids that matched no such image plus the unparsable ids;
    * `:added` / `:removed` - the resolved tag names, for the firehose broadcast.

  Returns `{:error, :unauthorized}` when `actor` may not batch-tag, or
  `{:error, {:batch_failed, failed_ids}}` (every castable id plus the
  unparsable ids) when the batch transaction does not commit.
  """
  @spec batch_update_tags(Actor.t(), String.t(), [IntegerId.integer_id()]) ::
          {:ok,
           %{succeeded: [integer()], failed: [any()], added: [String.t()], removed: [String.t()]}}
          | {:error, :unauthorized | {:batch_failed, [any()]}}
  def batch_update_tags(%Actor{} = actor, tag_list, image_ids) do
    with :ok <- authorize(actor, :batch_update, Tag) do
      tags = Tag.parse_tag_list(tag_list)

      added_tag_names = Enum.reject(tags, &String.starts_with?(&1, "-"))

      removed_tag_names =
        tags
        |> Enum.filter(&String.starts_with?(&1, "-"))
        |> Enum.map(&String.replace_leading(&1, "-", ""))

      added_tags =
        Tag
        |> where([t], t.name in ^added_tag_names)
        |> preload([:implied_tags, aliased_tag: :implied_tags])
        |> Repo.all()
        |> Enum.map(&(&1.aliased_tag || &1))
        |> Enum.flat_map(&[&1 | &1.implied_tags])

      removed_tags =
        Tag
        |> where([t], t.name in ^removed_tag_names)
        |> Repo.all()

      attributes = %{
        ip: actor.ip,
        fingerprint: actor.fingerprint,
        user_id: actor.user.id
      }

      {image_ids, unparsable_ids} = partition_image_ids(image_ids)

      log_batch = fn matched_ids ->
        ModerationLogs.create_moderation_log(
          actor.user,
          "Admin.Batch.Tag:update",
          Paths.profile_path(actor.user),
          "Batch tagged '#{tag_list}' on #{Enum.count(matched_ids)} images"
        )
      end

      case batch_update(image_ids, added_tags, removed_tags, attributes, log_batch) do
        {:ok, matched_ids} ->
          # Ids which parsed but matched no existing, non-hidden image were
          # never touched by the batch, so they are reported as failed.
          unmatched_ids = image_ids -- matched_ids

          {:ok,
           %{
             succeeded: matched_ids,
             failed: unmatched_ids ++ unparsable_ids,
             added: Enum.map(added_tags, & &1.name),
             removed: Enum.map(removed_tags, & &1.name)
           }}

        _error ->
          {:error, {:batch_failed, image_ids ++ unparsable_ids}}
      end
    end
  end

  # An id that is not an integer cannot name an image, so it is reported as
  # failed rather than crashing the whole batch.
  defp partition_image_ids(image_ids) do
    {parsed, unparsable} =
      image_ids
      |> Enum.map(&{&1, IntegerId.parse(&1)})
      |> Enum.split_with(&match?({_id, {:ok, _int}}, &1))

    {Enum.map(parsed, fn {_id, {:ok, int}} -> int end), Enum.map(unparsable, &elem(&1, 0))}
  end

  @doc """
  Performs a batch update on multiple images, adding and removing tags.

  This function efficiently updates tags for multiple images at once,
  handling tag changes, tag counts, and reindexing in a single transaction.

  ## Parameters
  - image_ids: List of image IDs to update
  - added_tags: List of tags to add to all images
  - removed_tags: List of tags to remove from all images
  - attributes: Attributes tag changes are created with

  ## Note

  All the tags provided to this function must exist in the database.
  If you're not sure if the tags exist or not, use Tags.get_or_create_tags first.

  ## Return value

  On success, returns `{:ok, image_ids}` where `image_ids` are the ids of
  the images the batch actually matched (existing, non-hidden images);
  requested ids that matched no such image are absent from the list.

  ## Examples

      iex> batch_update([1, 2], [tag1], [tag2], %{user_id: user.id, ip: ip, fingerprint: "ffff"})
      {:ok, [1, 2]}

  """
  @spec batch_update([integer()], [Tag.t()], [Tag.t()], map()) ::
          {:ok, [integer()]} | {:error, term()}
  def batch_update(image_ids, added_tags, removed_tags, attributes) do
    batch_update(image_ids, added_tags, removed_tags, attributes, fn _image_ids -> :ok end)
  end

  defp batch_update(image_ids, added_tags, removed_tags, attributes, after_changes) do
    batch_update(
      Enum.map(image_ids, fn id ->
        %{
          image_id: id,
          added_tags: added_tags,
          removed_tags: removed_tags
        }
      end),
      attributes,
      after_changes
    )
  end

  @spec batch_update([map()], map()) :: {:ok, [integer()]} | {:error, term()}
  def batch_update(changes, attributes) do
    batch_update(changes, attributes, fn _image_ids -> :ok end)
  end

  defp batch_update(changes, attributes, after_changes) do
    changes = merge_change_batches(changes)

    image_ids =
      Image
      |> where([i], i.id in ^Enum.map(changes, & &1.image_id) and i.hidden_from_users == false)
      |> select([i], i.id)
      |> Repo.all()

    # Window insertions to the matched (existing, non-hidden) images, like
    # the removals below: unmatched ids must never receive taggings, and
    # ids naming no image at all would violate the foreign key.
    matched_ids = MapSet.new(image_ids)

    to_insert =
      changes
      |> Enum.filter(&MapSet.member?(matched_ids, &1.image_id))
      |> Enum.flat_map(fn change ->
        Enum.map(change.added_tags, &%{tag_id: &1.id, image_id: change.image_id})
      end)

    to_delete_ids =
      Enum.flat_map(changes, fn change ->
        Enum.map(change.removed_tags, & &1.id)
      end)

    to_delete =
      Tagging
      |> where([t], t.image_id in ^image_ids and t.tag_id in ^to_delete_ids)
      |> select([t], [t.image_id, t.tag_id])

    now = DateTime.utc_now(:second)
    tag_attributes = %{name: "", slug: "", created_at: now, updated_at: now}

    Repo.transaction(fn ->
      {_count, inserted} =
        Repo.insert_all(Tagging, to_insert,
          on_conflict: :nothing,
          returning: [:image_id, :tag_id]
        )

      {_count, deleted} = Repo.delete_all(to_delete)

      inserted = Enum.map(inserted, &[&1.image_id, &1.tag_id])

      # Create tag change batches for every image ID.
      new_tag_changes =
        (inserted ++ deleted)
        |> Enum.uniq_by(fn [image_id, _] -> image_id end)
        |> Enum.map(fn [image_id, _] ->
          {:ok, tc} =
            %TagChange{
              image_id: image_id,
              user_id: attributes[:user_id],
              ip: attributes[:ip],
              fingerprint: attributes[:fingerprint],
              created_at: now
            }
            |> Repo.insert()

          {image_id, tc}
        end)
        |> Map.new()

      # Create tags belonging to tag changes.
      added_changes = tag_change_data(inserted, new_tag_changes, true)
      removed_changes = tag_change_data(deleted, new_tag_changes, false)

      Repo.insert_all(Philomena.TagChanges.TagChangeTag, added_changes ++ removed_changes)

      # In order to merge into the existing tables here in one go, insert_all
      # is used with a query that is guaranteed to conflict on every row by
      # using the primary key. This will update the image counts via the
      # ON CONFLICT DO UPDATE clause.

      added_upserts = tag_upsert_data(inserted, tag_attributes, true)
      removed_upserts = tag_upsert_data(deleted, tag_attributes, false)

      Repo.insert_all(Tag, added_upserts ++ removed_upserts,
        on_conflict: update(Tag, inc: [images_count: fragment("EXCLUDED.images_count")]),
        conflict_target: [:id]
      )

      case after_changes.(image_ids) do
        :ok -> :ok
        {:ok, _value} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      # Report the ids the batch actually matched back to the caller.
      image_ids
    end)
    |> case do
      {:ok, _} = result ->
        reindex_images(image_ids)
        Comments.reindex_comments_on_images(image_ids)
        Tags.reindex_tags(Enum.flat_map(changes, &(&1.added_tags ++ &1.removed_tags)))
        TagChanges.reindex_for_images(image_ids)

        result

      result ->
        result
    end
  end

  # Merge any change batches belonging to the same image ID into
  # one single batch, then deduplicate added_tags by removing any
  # which are slated for removal, which is the behavior of the
  # mass tagger anyway (it inserts anything that needs to be inserted
  # into image_taggings, and then deletes anything that needs to be deleted,
  # so by not inserting what would be deleted anyway, we're just mimicking
  # this behavior here, and ensuring that there are no duplicate tag changes
  # per batch)
  defp merge_change_batches(changes) do
    changes
    |> Enum.group_by(& &1.image_id)
    |> Enum.map(fn {image_id, instances} ->
      added =
        instances
        |> Enum.flat_map(& &1.added_tags)
        |> Enum.uniq_by(& &1.id)

      removed =
        instances
        |> Enum.flat_map(& &1.removed_tags)
        |> Enum.uniq_by(& &1.id)

      %{
        image_id: image_id,
        added_tags: Enum.reject(added, fn a -> Enum.any?(removed, &(&1.id == a.id)) end),
        removed_tags: removed
      }
    end)
    |> Enum.reject(&(Enum.empty?(&1.added_tags) && Enum.empty?(&1.removed_tags)))
  end

  # Generate data for TagChanges.TagChangeTag rows.
  defp tag_change_data(changes, tag_changes, added) do
    Enum.map(changes, fn [image_id, tag_id] ->
      %{id: id} = Map.get(tag_changes, image_id)

      %{
        tag_change_id: id,
        tag_id: tag_id,
        added: added
      }
    end)
  end

  # Generate data for inserts/updates (hence, upserts) of the Tags.Tag struct.
  defp tag_upsert_data(changes, tag_attributes, added) do
    changes
    |> Enum.group_by(fn [_image_id, tag_id] -> tag_id end)
    |> Enum.map(fn {tag_id, instances} ->
      Map.merge(tag_attributes, %{
        id: tag_id,
        images_count: if(added, do: length(instances), else: -length(instances))
      })
    end)
  end

  @doc """
  Updates image search indices when a user's name changes.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  @spec user_name_reindex(String.t(), String.t()) :: term()
  def user_name_reindex(old_name, new_name) do
    data = Images.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Image, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Removes the vote cast by the user named by `user_id` on the image named by
  `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:tamper`; the target user is then
  loaded by id. A non-castable or unknown user is is `{:error, :not_found}`, checked
  after image authorization. Removing a vote the user never cast still succeeds.
  On success the image is reindexed and a moderation log recording the removed vote
  type and target user is written.

  Returns `{:ok, image}` with the image.

  ## Examples

      iex> delete_user_vote(moderator, "42", "7")
      {:ok, %Image{}}

      iex> delete_user_vote(user, "42", "7")
      {:error, :unauthorized}

  """
  @spec delete_user_vote(
          actor :: Actor.t(),
          image_id :: IntegerId.integer_id(),
          user_id :: IntegerId.integer_id()
        ) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def delete_user_vote(%Actor{} = actor, image_id, user_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :tamper, image_id),
         {:ok, user} <- load_vote_user(user_id) do
      Multi.new()
      |> ImageVotes.delete_vote_for_loaded_image(image, user)
      |> ModerationLogs.put_log(:moderation_log, actor, fn changes ->
        vote_type = deleted_vote_type(changes)

        {
          "Image.Tamper:create",
          Paths.image_path(image),
          "Deleted #{vote_type} by #{user.name} on image #{image.id}"
        }
      end)
      |> Multi.on_commit(fn _changes -> reindex_image(image) end)
      |> Multi.transact()
      |> case do
        {:ok, _changes} -> {:ok, image}
        error -> error
      end
    end
  end

  defp deleted_vote_type(%{undownvote: {1, _}}), do: "downvote"
  defp deleted_vote_type(%{unupvote: {1, _}}), do: "upvote"
  defp deleted_vote_type(_changes), do: "vote"

  # The target user is loaded with no authorization: an unknown or non-castable
  # id is a plain not-found.
  defp load_vote_user(user_id) do
    with {:ok, id} <- Loader.parse_id(user_id),
         %User{} = user <- Repo.get(User, id) do
      {:ok, user}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Adds an after-commit image reindex step to a transaction workflow.

  The referenced step must resolve to an image. The indexing job is enqueued
  only after the database transaction commits.
  """
  @spec put_reindex_image(Multi.t(), Ecto.Multi.name()) :: Multi.t()
  def put_reindex_image(%Multi{} = multi, step) do
    Multi.on_commit(multi, fn %{^step => image} -> reindex_image(image) end)
  end

  @doc """
  Loads an image for an invariant-enforced indexing job.

  This worker service raises when the queued image no longer exists; request
  paths must use an actor-scoped loader instead.

  ## Examples

      iex> load_image_for_reindex!(42)
      %Image{}

  """
  @spec load_image_for_reindex!(integer()) :: Image.t()
  def load_image_for_reindex!(image_id) when is_integer(image_id) do
    Repo.one!(Image |> where(id: ^image_id) |> preload(:tags))
  end

  @doc """
  Queues a single image for search index updates.
  Returns the image struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_image(image)
      %Image{}

  """
  @spec reindex_image(Image.t()) :: Image.t()
  def reindex_image(%Image{} = image) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Images", "id", [image.id]])

    image
  end

  @doc """
  Queues all listed image IDs for search index updates.
  Returns the list unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_images([1, 2, 3])
      [1, 2, 3]

  """
  @spec reindex_images([integer()]) :: [integer()]
  def reindex_images(image_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Images", "id", image_ids])

    image_ids
  end

  @doc """
  Returns the preload configuration for image indexing.

  Specifies which associations should be preloaded when indexing images,
  optimizing the queries for better performance.

  ## Examples

      iex> indexing_preloads()
      [sources: query, user: query, ...]

  """
  @spec indexing_preloads() :: list()
  def indexing_preloads do
    user_query = select(User, [u], map(u, [:id, :name]))
    sources_query = select(Source, [s], map(s, [:image_id, :source]))
    alias_tags_query = select(Tag, [t], map(t, [:aliased_tag_id, :name]))

    base_tags_query =
      Tag
      |> select([t], [:category, :id, :name])
      |> preload(aliases: ^alias_tags_query)

    [
      :gallery_interactions,
      sources: sources_query,
      user: user_query,
      favers: user_query,
      downvoters: user_query,
      upvoters: user_query,
      hiders: user_query,
      subscribers: user_query,
      deleter: user_query,
      tags: base_tags_query
    ]
  end

  @doc """
  Performs the worker-side search reindex operation for images matching the
  given criteria. PostgreSQL is the source of truth; OpenSearch is updated
  asynchronously by the indexing jobs queued elsewhere in this context.

  ## Parameters
  - column: The database column to filter on (e.g., :id)
  - condition: A list of values to match against the column

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      :ok

  """
  @spec perform_reindex(atom(), [term()]) :: term()
  def perform_reindex(column, condition) do
    Image
    |> preload(^indexing_preloads())
    |> where([i], field(i, ^column) in ^condition)
    |> Search.reindex(Image)
  end

  defp purge_files(image, hidden_key) do
    files =
      if is_nil(hidden_key) do
        Thumbnailer.thumbnail_urls(image, nil)
      else
        Thumbnailer.thumbnail_urls(image, hidden_key) ++
          Thumbnailer.thumbnail_urls(image, nil)
      end

    Exq.enqueue(Exq, "indexing", ImagePurgeWorker, [files])
  end

  @doc """
  Executes the worker-side CDN purge operation for image files.

  Calls the system purge-cache command to remove the specified files from the CDN cache.

  ## Examples

      iex> perform_purge(["file1.jpg", "file2.jpg"])
      :ok

  """
  @spec perform_purge([String.t()]) :: :ok
  def perform_purge(files) do
    {_out, 0} = System.cmd("purge-cache", [JSON.encode!(%{files: files})])

    :ok
  end

  alias Philomena.Images.Subscription

  defp migrate_subscriptions(source, target) do
    subscriptions =
      Subscription
      |> where(image_id: ^source.id)
      |> select([s], %{image_id: type(^target.id, :integer), user_id: s.user_id})
      |> Repo.all()

    Repo.insert_all(Subscription, subscriptions, on_conflict: :nothing)

    comment_notifications =
      from cn in ImageCommentNotification,
        where: cn.image_id == ^source.id,
        select: %{
          user_id: cn.user_id,
          image_id: ^target.id,
          comment_id: cn.comment_id,
          read: cn.read,
          created_at: cn.created_at,
          updated_at: cn.updated_at
        }

    merge_notifications =
      from mn in ImageMergeNotification,
        where: mn.target_id == ^source.id,
        select: %{
          user_id: mn.user_id,
          target_id: ^target.id,
          source_id: mn.source_id,
          read: mn.read,
          created_at: mn.created_at,
          updated_at: mn.updated_at
        }

    {comment_notification_count, nil} =
      Repo.insert_all(ImageCommentNotification, comment_notifications, on_conflict: :nothing)

    {merge_notification_count, nil} =
      Repo.insert_all(ImageMergeNotification, merge_notifications, on_conflict: :nothing)

    Repo.delete_all(exclude(comment_notifications, :select))
    Repo.delete_all(exclude(merge_notifications, :select))

    {:ok, {comment_notification_count, merge_notification_count}}
  end

  defp notify_merge(_repo, _changes, source, target) do
    Notifications.broadcast_image_merge(target, source)
  end

  @doc """
  Subscribes `actor` to the image named by `image_id`, so they are notified of
  new comments on it.

  The image is loaded by id and authorized for `:subscribe`. Subscribing is
  idempotent and uses the same write-access gate as other interactions.

  Returns `{:ok, image}`, or `{:error, %Ecto.Changeset{}}` if the subscription
  insert is rejected.

  ## Examples

      iex> subscribe_image(user, "42")
      {:ok, %Image{}}

      iex> subscribe_image(user, "999999999")
      {:error, :not_found}

  """
  @spec subscribe_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def subscribe_image(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :subscribe, image_id),
         {:ok, _subscription} <- create_subscription(image, actor.user) do
      {:ok, image}
    end
  end

  @doc """
  Unsubscribes `actor` from the image named by `image_id`.

  Loading and authorization mirror `subscribe_image/2`. Unsubscribing is
  idempotent and cannot fail, so there is no changeset error shape.

  Returns `{:ok, image}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unsubscribe_image(user, "42")
      {:ok, %Image{}}

  """
  @spec unsubscribe_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def unsubscribe_image(%Actor{} = actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <- load_image_member(actor, :unsubscribe, image_id) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(image, actor.user)
      {:ok, image}
    end
  end

  @doc """
  Records a personal hide of the image named by `image_id` for `actor`, so the
  image is filtered out of `actor`'s browsing. This is the per-user hide
  interaction, distinct from the moderator hide `hide_image/3`.

  Banned actors are rejected first with `{:error, :ban}` (a write with no
  fingerprint is `{:error, :unauthorized}`), before the image is loaded. The
  image is then loaded by id and authorized for `:vote`. Hiding is
  idempotent.

  Returns `{:ok, image}` with the image reloaded and reindexed (so its hide count
  is current), or `{:error, :hide_failed}` if the hide transaction is rolled back.

  ## Examples

      iex> create_image_hide(actor, "42")
      {:ok, %Image{}}

  """
  @spec create_image_hide(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found | :hide_failed}
  def create_image_hide(actor, image_id) do
    with {:ok, image} <- load_image_for_hide(actor, image_id) do
      Multi.new()
      |> ImageHides.put_hide_for_loaded_image(image, actor.user)
      |> Multi.transact()
      |> hide_result(image)
    end
  end

  @doc """
  Removes `actor`'s personal hide of the image named by `image_id`. This is the
  per-user unhide interaction, distinct from the moderator unhide `unhide_image/2`.

  Loading, authorization, and ban semantics mirror `create_image_hide/2`.
  Removing a hide is idempotent.

  Returns `{:ok, image}` with the image reloaded and reindexed, or
  `{:error, :hide_failed}` if the transaction is rolled back.

  ## Examples

      iex> delete_image_hide(actor, "42")
      {:ok, %Image{}}

  """
  @spec delete_image_hide(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found | :hide_failed}
  def delete_image_hide(actor, image_id) do
    with {:ok, image} <- load_image_for_hide(actor, image_id) do
      Multi.new()
      |> ImageHides.delete_hide_for_loaded_image(image, actor.user)
      |> Multi.transact()
      |> hide_result(image)
    end
  end

  # Shared loader for the per-user hide interaction: a banned actor is rejected
  # first, then the image is loaded by id and authorized for `:vote`.
  defp load_image_for_hide(actor, image_id) do
    with :ok <- verify_write_access(actor) do
      load_image_member(actor, :vote, image_id)
    end
  end

  defp parse_vote(up) when up in [true, "true"], do: {:ok, true}
  defp parse_vote(up) when up in [false, "false"], do: {:ok, false}
  defp parse_vote(_up), do: {:error, :invalid_vote}

  defp hide_result({:ok, _changes}, image),
    do: {:ok, Repo.get!(preload(Image, :tags), image.id) |> reindex_image()}

  defp hide_result(_error, _image), do: {:error, :hide_failed}

  defp load_image_for_interaction(actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, image} <-
           load_image_member(actor, :vote, image_id, [:sources, tags: :aliases]),
         :ok <- Filtering.verify_not_forced(actor, image) do
      {:ok, image}
    end
  end

  @doc """
  Verifies the Images-owned forced-filter prerequisite for a loaded image.

  This narrow cross-context service is used by comment actions after image
  authorization succeeds. Controllers must call their owning action instead.

  ## Examples

      iex> verify_forced_filter_access(actor, image)
      :ok

  """
  @spec verify_forced_filter_access(Actor.t(), Image.t()) ::
          :ok | {:error, :forced_filter}
  def verify_forced_filter_access(%Actor{} = actor, %Image{} = image) do
    Filtering.verify_not_forced(actor, image)
  end

  @doc """
  Records `actor`'s fave of `image_id`, which also casts an implicit upvote
  (replacing an existing downvote). Faving is idempotent.

  Write access, image authorization, and forced-filter enforcement happen before
  the transaction.

  ## Examples

      iex> create_fave(actor, "42")
      {:ok, %Image{}}

  """
  @spec create_fave(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()}
          | {:error, :ban | :unauthorized | :not_found | :forced_filter | :interaction_failed}
  def create_fave(%Actor{user: user} = actor, image_id) do
    with {:ok, image} <- load_image_for_interaction(actor, image_id) do
      Multi.new()
      |> ImageFaves.put_fave_for_loaded_image(image, user)
      |> ImageVotes.put_vote_for_loaded_image(image, user, true)
      |> Multi.transact()
      |> interaction_result(image)
    end
  end

  @doc """
  Removes `actor`'s fave of `image_id`, leaving any upvote in place. Unfaving is
  idempotent and enforces the same prerequisites as `create_fave/2`.

  Returns `{:ok, image}` with the image reloaded and reindexed, or
  `{:error, :interaction_failed}` if the transaction is rolled back.

  ## Examples

      iex> delete_fave(actor, "42")
      {:ok, %Image{}}

  """
  @spec delete_fave(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()}
          | {:error, :ban | :unauthorized | :not_found | :forced_filter | :interaction_failed}
  def delete_fave(%Actor{user: user} = actor, image_id) do
    with {:ok, image} <- load_image_for_interaction(actor, image_id) do
      Multi.new()
      |> ImageFaves.delete_fave_for_loaded_image(image, user)
      |> Multi.transact()
      |> interaction_result(image)
    end
  end

  @doc """
  Records `actor`'s vote on `image_id`—an upvote when `up` is `true` or
  `"true"`, and a downvote when it is `false` or `"false"`—replacing any
  existing vote. Other values return `{:error, :invalid_vote}`. Voting is
  idempotent.

  Write access, image authorization, and forced-filter enforcement happen before
  the transaction.

  ## Examples

      iex> create_vote(actor, "42", true)
      {:ok, %Image{}}

  """
  @spec create_vote(Actor.t(), IntegerId.integer_id(), term()) ::
          {:ok, Image.t()}
          | {:error,
             :ban
             | :unauthorized
             | :not_found
             | :forced_filter
             | :invalid_vote
             | :interaction_failed}
  def create_vote(%Actor{user: user} = actor, image_id, up) do
    with {:ok, image} <- load_image_for_interaction(actor, image_id),
         {:ok, up} <- parse_vote(up) do
      Multi.new()
      |> ImageVotes.put_vote_for_loaded_image(image, user, up)
      |> Multi.transact()
      |> interaction_result(image)
    end
  end

  @doc """
  Removes `actor`'s vote on `image_id`. Unvoting is idempotent and enforces the
  same prerequisites as `create_vote/3`.

  Returns `{:ok, image}` with the image reloaded and reindexed, or
  `{:error, :interaction_failed}` if the transaction is rolled back.

  ## Examples

      iex> delete_vote(actor, "42")
      {:ok, %Image{}}

  """
  @spec delete_vote(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()}
          | {:error, :ban | :unauthorized | :not_found | :forced_filter | :interaction_failed}
  def delete_vote(%Actor{user: user} = actor, image_id) do
    with {:ok, image} <- load_image_for_interaction(actor, image_id) do
      Multi.new()
      |> ImageVotes.delete_vote_for_loaded_image(image, user)
      |> Multi.transact()
      |> interaction_result(image)
    end
  end

  defp interaction_result({:ok, _changes}, image),
    do: {:ok, Repo.get!(preload(Image, :tags), image.id) |> reindex_image()}

  defp interaction_result(_error, _image), do: {:error, :interaction_failed}

  @doc """
  Assembles the interaction listing for the image named by `image_id`, on behalf
  of `actor`.

  The image is loaded by id and authorized for `:index` (visible for any
  non-hidden image, and to staff for hidden ones).

  The image is returned with its faves preloaded. Votes and hides are loaded and
  `has_votes` is `true` only when `actor` may `:tamper` with the image;
  otherwise `has_votes` is `false` and those associations are not fetched.

  Returns `{:ok, {image, has_votes}}`.

  ## Examples

      iex> image_fave_list(moderator, "42")
      {:ok, {%Image{}, true}}

      iex> image_fave_list(user, "42")
      {:ok, {%Image{}, false}}

  """
  @spec image_fave_list(Actor.t(), IntegerId.integer_id()) ::
          {:ok, {Image.t(), boolean()}} | {:error, :unauthorized | :not_found}
  def image_fave_list(%Actor{} = actor, image_id) do
    with {:ok, image} <- load_image_member(actor, :index, image_id, faves: :user) do
      case authorize(actor, :tamper, image) do
        :ok ->
          {:ok, {Repo.preload(image, upvotes: :user, downvotes: :user, hides: :user), true}}

        {:error, :unauthorized} ->
          {:ok, {image, false}}
      end
    end
  end

  @doc """
  Clears `actor`'s unread notifications for the image named by `image_id`.

  The image is loaded before `:mark_read` authorization. Missing IDs are
  actor-independent.

  Returns `{:ok, image}` after clearing `actor`'s image comment and image merge
  notifications for it.

  ## Examples

      iex> mark_image_read(user, "42")
      {:ok, %Image{}}

      iex> mark_image_read(user, "nonexistent")
      {:error, :not_found}

  """
  @spec mark_image_read(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def mark_image_read(%Actor{} = actor, image_id) do
    with {:ok, image} <- load_image_member(actor, :mark_read, image_id) do
      clear_image_notification(image, actor.user)
      {:ok, image}
    end
  end

  # Invoked dynamically by the shared subscription implementation.
  @doc false
  @spec clear_image_notification(Image.t(), User.t() | nil) :: :ok
  def clear_image_notification(%Image{} = image, user) do
    Notifications.clear_image_comment(image, user)
    Notifications.clear_image_merge(image, user)
    :ok
  end
end
