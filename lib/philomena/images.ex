defmodule Philomena.Images do
  @moduledoc """
  The Images context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  require Logger

  alias Ecto.Multi
  alias Philomena.Repo

  alias PhilomenaQuery.Search
  alias Philomena.ThumbnailWorker
  alias Philomena.ImagePurgeWorker
  alias Philomena.DuplicateReports.DuplicateReport
  alias Philomena.Images.Image
  alias Philomena.Images.Uploader
  alias Philomena.Images.Tagging
  alias Philomena.Images.Thumbnailer
  alias Philomena.Images.Source
  alias Philomena.Images
  alias Philomena.IntegerId
  alias Philomena.IndexWorker
  alias Philomena.IntegerId
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
  alias Philomena.Comments.Comment
  alias Philomena.Galleries
  alias Philomena.Galleries.Gallery
  alias Philomena.Galleries.Interaction
  alias Philomena.Images.ImagePage
  alias Philomena.Images.Query, as: ImageQuery
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Users.User
  alias Philomena.Users

  use Philomena.Subscriptions,
    on_delete: :clear_image_notification,
    id_name: :image_id

  @doc """
  Gets a single image.

  Raises `Ecto.NoResultsError` if the Image does not exist.

  ## Examples

      iex> get_image!(123)
      %Image{}

      iex> get_image!(456)
      ** (Ecto.NoResultsError)

  """
  def get_image!(id) do
    Repo.one!(Image |> where(id: ^id) |> preload(:tags))
  end

  @doc """
  Loads the image `id`, with its uploader, intensities, sources, and tags
  preloaded.

  Viewing needs no permission: a hidden image is still returned. Returns
  `{:ok, image}`, or `{:error, :not_found}` when no row matches.

  ## Examples

      iex> load_image("1")
      {:ok, %Image{}}

      iex> load_image("0")
      {:error, :not_found}

  """
  @spec load_image(IntegerId.integer_id()) :: {:ok, Image.t()} | {:error, :not_found}
  def load_image(id) do
    # The id is interpolated without parsing, so a non-integer value raises
    # Ecto.Query.CastError.
    # TODO: don't raise an error?
    Image
    |> where(id: ^id)
    |> preload([:user, :intensity, :sources, tags: :aliases])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      image -> {:ok, image}
    end
  end

  @doc """
  Loads the most recently featured non-hidden image, with its uploader,
  intensities, sources, and tags preloaded.

  Returns `{:ok, image}`, or `{:error, :not_found}` when no eligible feature
  exists.

  ## Examples

      iex> featured_image()
      {:ok, %Image{}}

      iex> featured_image()
      {:error, :not_found}

  """
  @spec featured_image() :: {:ok, Image.t()} | {:error, :not_found}
  def featured_image do
    Image
    |> join(:inner, [i], f in ImageFeature, on: [image_id: i.id])
    |> where([i], i.hidden_from_users == false)
    |> order_by([_i, f], desc: f.created_at)
    |> limit(1)
    |> preload([:user, :intensity, :sources, tags: :aliases])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      image -> {:ok, image}
    end
  end

  @doc """
  Creates a image.

  ## Examples

      iex> create_image(%{field: value})
      {:ok, %Image{}}

      iex> create_image(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_image(Users.principal(), %{String.t() => any()}) ::
          {:ok, image_upload()} | Ecto.Multi.failure()
  def create_image(attribution, attrs \\ %{}) do
    # FIXME: attribution use. use Actor.t()
    tags = Tags.get_or_create_tags(attrs["tag_input"])
    sources = attrs["sources"]

    image =
      %Image{}
      |> Image.creation_changeset(attrs, attribution)
      |> Image.source_changeset(attrs, [], sources)
      |> Image.tag_changeset(attrs, [], tags)
      |> Image.dnp_changeset(attribution[:user])
      |> Uploader.analyze_upload(attrs)

    Multi.new()
    |> Multi.insert(:image, image)
    |> Multi.run(:added_tag_count, fn repo, %{image: image} ->
      tag_ids = image.added_tags |> Enum.map(& &1.id)

      count = Tags.update_image_counts(repo, 1, tag_ids)

      {:ok, count}
    end)
    |> maybe_subscribe_on(:image, attribution[:user], :watch_on_upload)
    |> Repo.transaction()
    |> case do
      {:ok, %{image: image}} ->
        upload_pid = async_upload(image, attrs["image"])
        reindex_image(image)
        Tags.reindex_tags(image.added_tags)
        maybe_approve_image(image, attribution[:user])

        # Return the upload PID along with the created image so that the caller
        # can control the lifecycle of the upload if needed. It's useful, for
        # example for the seeding process to know when to delete the temp file
        # used for uploading.
        {:ok, %{image: image, upload_pid: upload_pid}}

      result ->
        result
    end
  end

  @doc """
  Updates an image's description.

  ## Examples

      iex> update_description(image, %{"description" => "New description"})
      {:ok, %Image{}}

  """
  def update_description(%Image{} = image, attrs) do
    image
    |> Image.description_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Changes the uploader of an image.

  ## Examples

      iex> update_uploader(image, %{"username" => "Admin"})
      {:ok, %Image{}}

  """
  def update_uploader(%Image{} = image, attrs) do
    image
    |> Image.uploader_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Updates the anonymous status of an image.

  ## Examples

      iex> update_anonymous(image, %{"anonymous" => "true"})
      {:ok, %Image{}}

  """
  def update_anonymous(%Image{} = image, attrs) do
    image
    |> Image.anonymous_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Approves an image for public viewing.

  This will make the image visible to users and update necessary statistics.

  ## Examples

      iex> approve_image(image)
      {:ok, %Image{}}
  """
  def approve_image(image) do
    image
    |> Repo.preload(:user)
    |> Image.approve_changeset()
    |> Repo.update()
    |> case do
      {:ok, image} ->
        reindex_image(image)
        increment_user_stats(image.user)
        maybe_suggest_user_verification(image.user)

        {:ok, image}

      error ->
        error
    end
  end

  @doc """
  Hides the given already-loaded image from public view. This is the internal
  hide engine; it performs no authorization and writes no moderation log, so
  callers needing those go through `hide_image/3`.

  This will:
  1. Mark the image as hidden
  2. Close all reports and duplicate reports
  3. Delete all gallery interactions containing the image
  4. Decrement all tag counts with the image
  5. Hide the image's thumbnails and purge them from the CDN
  6. Reindex the image and all of its comments

  ## Examples

      iex> hide_loaded_image(image, moderator, %{reason: "Rule violation"})
      {:ok,
       %{
         image: image,
         tags: tags,
         reports: {count, reports}
       }}

  """
  def hide_loaded_image(%Image{} = image, user, attrs) do
    duplicate_reports =
      DuplicateReport
      |> where(state: "open")
      |> where([d], d.image_id == ^image.id or d.duplicate_of_image_id == ^image.id)
      |> update(set: [state: "rejected"])

    image
    |> Image.hide_changeset(attrs, user)
    |> hide_image_multi(image, user, Multi.new())
    |> Multi.update_all(:duplicate_reports, duplicate_reports, [])
    |> Repo.transaction()
    |> process_after_hide()
  end

  @doc """
  Unhides an image, making it visible to users again.

  This will:
  1. Remove the hidden status from the image
  2. Increment tag counts
  3. Unhide thumbnails
  4. Reindex the image and related content

  Returns {:ok, image} if successful, or returns the image unchanged if it's not hidden.

  ## Examples

      iex> unhide_image(hidden_image)
      {:ok, %Image{hidden_from_users: false}}

      iex> unhide_image(visible_image)
      {:ok, %Image{}}

  """
  def unhide_image(%Image{hidden_from_users: true} = image) do
    key = image.hidden_image_key

    Multi.new()
    |> Multi.update(:image, Image.unhide_changeset(image))
    |> Multi.run(:tags, fn repo, %{image: image} ->
      image = Repo.preload(image, :tags, force: true)

      tag_ids = Enum.map(image.tags, & &1.id)
      query = where(Tag, [t], t.id in ^tag_ids)

      repo.update_all(query, inc: [images_count: 1])

      {:ok, image.tags}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{image: image, tags: tags}} ->
        spawn(fn ->
          Thumbnailer.unhide_thumbnails(image, key)
        end)

        reindex_image(image)
        purge_files(image, image.hidden_image_key)
        Comments.reindex_comments_on_image(image)
        Tags.reindex_tags(tags)

        {:ok, image}

      error ->
        error
    end
  end

  def unhide_image(image), do: {:ok, image}

  @doc """
  Merges one image into another, combining their metadata and content.

  This will:
  1. Hide the source image
  2. Update first_seen_at timestamp
  3. Copy tags to the target image
  4. Migrate sources, comments, subscriptions and interactions
  5. Send merge notifications
  6. Reindex both images and all of the comments

  ## Parameters
  - multi: Optional `m:Ecto.Multi` for transaction handling
  - image: The source image to merge from
  - duplicate_of_image: The target image to merge into
  - user: The user performing the merge

  ## Examples

      iex> merge_image(nil, source_image, target_image, moderator)
      {:ok,
       %{
         image: image,
         tags: tags
       }}

  """
  def merge_image(multi \\ nil, %Image{} = image, duplicate_of_image, user) do
    multi = multi || Multi.new()

    image =
      Repo.preload(image, [:user, :intensity, :sources, tags: :aliases])

    duplicate_of_image =
      Repo.preload(duplicate_of_image, [:user, :intensity, :sources, tags: :aliases])

    image
    |> Image.merge_changeset(duplicate_of_image)
    |> hide_image_multi(image, user, multi)
    |> Multi.run(:first_seen_at, fn _, %{} ->
      update_first_seen_at(
        duplicate_of_image,
        image.first_seen_at,
        duplicate_of_image.first_seen_at
      )
    end)
    |> Multi.run(:copy_tags, fn _, %{} ->
      {:ok, Tags.copy_tags(image, duplicate_of_image)}
    end)
    |> Multi.run(:migrate_sources, fn _, %{} ->
      {:ok, migrate_sources(image, duplicate_of_image)}
    end)
    |> Multi.run(:migrate_comments, fn _, %{} ->
      {:ok, Comments.migrate_comments(image, duplicate_of_image)}
    end)
    |> Multi.run(:migrate_subscriptions, fn _, %{} ->
      {:ok, migrate_subscriptions(image, duplicate_of_image)}
    end)
    |> Multi.run(:migrate_interactions, fn _, %{} ->
      {:ok, Interactions.migrate_interactions(image, duplicate_of_image)}
    end)
    |> Multi.run(:notification, &notify_merge(&1, &2, image, duplicate_of_image))
    |> Repo.transaction()
    |> process_after_hide()
    |> case do
      {:ok, result} ->
        reindex_image(duplicate_of_image)
        Comments.reindex_comments_on_image(duplicate_of_image)

        PhilomenaWeb.Endpoint.broadcast!(
          "firehose",
          "image:merge",
          %{
            image: PhilomenaWeb.Api.Json.ImageView.render("image.json", %{image: image}),
            duplicate_of_image:
              PhilomenaWeb.Api.Json.ImageView.render("image.json", %{image: duplicate_of_image})
          }
        )

        {:ok, result}

      error ->
        error
    end
  end

  defp hide_image_multi(changeset, image, user, multi) do
    report_query = Reports.close_report_query({"Image", image.id}, user)

    galleries =
      Gallery
      |> join(:inner, [g], gi in assoc(g, :interactions), on: gi.image_id == ^image.id)
      |> update(inc: [image_count: -1])

    gallery_interactions = where(Interaction, image_id: ^image.id)

    multi
    |> Multi.update(:image, changeset)
    |> Multi.update_all(:reports, report_query, [])
    |> Multi.update_all(:galleries, galleries, [])
    |> Multi.delete_all(:gallery_interactions, gallery_interactions, [])
    |> Multi.run(:tags, fn repo, %{image: image} ->
      image = Repo.preload(image, :tags, force: true)

      # I'm not convinced this is a good idea. It leads
      # to way too much drift, and the index has to be
      # maintained.
      tag_ids = Enum.map(image.tags, & &1.id)

      Tags.update_image_counts(repo, -1, tag_ids)

      {:ok, image.tags}
    end)
  end

  defp process_after_hide(result) do
    case result do
      {:ok, %{image: image, tags: tags, reports: {_count, reports}} = result} ->
        spawn(fn ->
          Thumbnailer.hide_thumbnails(image, image.hidden_image_key)
          purge_files(image, image.hidden_image_key)
        end)

        Comments.reindex_comments_on_image(image)
        Reports.reindex_reports(reports)
        Tags.reindex_tags(tags)
        reindex_image(image)
        reindex_copied_tags(result)

        {:ok, result}

      error ->
        error
    end
  end

  defp reindex_copied_tags(%{copy_tags: tags}), do: Tags.reindex_tags(tags)
  defp reindex_copied_tags(_result), do: nil

  defp update_first_seen_at(image, time_1, time_2) do
    min_time =
      case DateTime.compare(time_1, time_2) do
        :gt -> time_2
        _ -> time_1
      end

    Image
    |> where(id: ^image.id)
    |> Repo.update_all(set: [first_seen_at: min_time])

    {:ok, image}
  end

  @doc """
  Destroys the contents of an image (hard deletion) by marking it as hidden
  and deleting up associated files.

  This will:
  1. Mark the image as removed in the database
  2. Purge associated files
  3. Remove thumbnails

  ## Examples

      iex> destroy_image(image)
      {:ok, %Image{}}

  """
  def destroy_image(%Image{} = image) do
    image
    |> Image.remove_image_changeset()
    |> Repo.update()
    |> case do
      {:ok, image} ->
        purge_files(image, image.hidden_image_key)
        Thumbnailer.destroy_thumbnails(image)

        {:ok, image}

      error ->
        error
    end
  end

  @doc """
  Locks or unlocks comments on an image.

  ## Examples

      iex> lock_comments(image, true)
      {:ok, %Image{}}

  """
  def lock_comments(%Image{} = image, locked) do
    image
    |> Image.lock_comments_changeset(locked)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Locks or unlocks the description of an image.

  ## Examples

      iex> lock_description(image, true)
      {:ok, %Image{}}

  """
  def lock_description(%Image{} = image, locked) do
    image
    |> Image.lock_description_changeset(locked)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Locks or unlocks the tags on an image.

  ## Examples

      iex> lock_tags(image, true)
      {:ok, %Image{}}

  """
  def lock_tags(%Image{} = image, locked) do
    image
    |> Image.lock_tags_changeset(locked)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Removes the original SHA-512 hash from an image, allowing users to upload
  the same file again.

  ## Examples

      iex> remove_hash(image)
      {:ok, %Image{}}

  """
  def remove_hash(%Image{} = image) do
    image
    |> Image.remove_hash_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Updates the scratchpad notes on an image.

  ## Examples

      iex> update_scratchpad(image, %{"scratchpad" => "New notes"})
      {:ok, %Image{}}

  """
  def update_scratchpad(%Image{} = image, attrs) do
    image
    |> Image.scratchpad_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Removes all source change history for an image.

  ## Examples

      iex> remove_source_history(image)
      {:ok, %Image{}}

  """
  def remove_source_history(%Image{} = image) do
    image
    |> Repo.preload(:source_changes)
    |> Image.remove_source_history_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Updates the file content of an image.

  This will:
  1. Update the image metadata
  2. Save the new file
  3. Generate new thumbnails
  4. Purge old files
  5. Reindex the image

  ## Examples

      iex> update_file(image, %{"image" => upload})
      {:ok, %Image{}}

  """
  def update_file(%Image{} = image, attrs) do
    image
    |> Image.changeset(attrs)
    |> Uploader.analyze_upload(attrs)
    |> Repo.update()
    |> case do
      {:ok, image} ->
        Uploader.persist_upload(image)

        repair_image(image)
        purge_files(image, image.hidden_image_key)
        reindex_image(image)

        {:ok, image}

      error ->
        error
    end
  end

  @doc """
  Updates the hide reason for an image.

  ## Examples

      iex> update_hide_reason(image, %{hide_reason: "Duplicate of #1234"})
      {:ok, %Image{}}

      iex> update_hide_reason(image, %{hide_reason: ""})
      {:ok, %Image{}}

  """
  def update_hide_reason(%Image{} = image, attrs) do
    image
    |> Image.hide_reason_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Updates the sources of the given already-loaded image with attribution
  tracking. This is the internal source engine; it performs no authorization,
  so callers needing authorization go through `update_sources/3`.

  Handles both added and removed sources. Automatically determines the user's
  intended source changes based on the provided previous image state. `attribution`
  is the keyword-list principal (`[ip:, fingerprint:, user:]`) attributed to the
  created source change records.

  This will update the image's sources and create source change records for
  tracking.

  ## Examples

      iex> update_loaded_sources(
      ...>   image,
      ...>   [ip: ip, fingerprint: fp, user: user],
      ...>   %{
      ...>     "old_sources" => %{},
      ...>     "sources" => %{"0" => "http://example.com"}
      ...>    }
      ...> )
      {:ok,
       %{
         image: {image, added_sources, removed_sources},
         added_source_changes: 1,
         removed_source_changes: 0
       }}

  """
  def update_loaded_sources(%Image{} = image, attribution, attrs) do
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
        |> Enum.map(&source_change_attributes(attribution, image, &1, true, attribution[:user]))

      {count, nil} = repo.insert_all(SourceChange, source_changes)

      {:ok, count}
    end)
    |> Multi.run(:removed_source_changes, fn repo, %{image: {image, _added, removed_sources}} ->
      source_changes =
        removed_sources
        |> Enum.map(&source_change_attributes(attribution, image, &1, false, attribution[:user]))

      {count, nil} = repo.insert_all(SourceChange, source_changes)

      {:ok, count}
    end)
    |> Repo.transaction()
  end

  @doc """
  Updates the tags of the given already-loaded image with attribution tracking.
  This is the internal tag engine; it performs no authorization, so
  callers needing authorization go through `update_tags/3`.

  Handles both added and removed tags. Automatically determines the user's
  intended tag changes based on the provided previous image state. `attribution`
  is the keyword-list principal (`[ip:, fingerprint:, user:]`) attributed to the
  created tag change records; it also enforces the per-identity tag-change rate
  limit inside the transaction.

  This will update the image's tags and create tag change records for tracking.

  ## Examples

      iex> update_loaded_tags(
      ...>   image,
      ...>   [ip: ip, fingerprint: fp, user: user],
      ...>   %{
      ...>     "old_tag_input" => "safe",
      ...>     "tag_input" => "safe, cute"
      ...>   }
      ...> )
      {:ok,
       %{
         image: {image, added_tags, removed_tags},
         tag_changes: {1, 0}
       }}

  """
  def update_loaded_tags(%Image{} = image, attribution, attrs) do
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
      check_tag_change_limits_before_commit(image, attribution)
    end)
    |> Multi.run(:tag_changes, fn
      _repo, %{image: {_image, [], []}} ->
        {:ok, {0, 0}}

      _repo, %{image: {image, added_tags, removed_tags}} ->
        TagChanges.create_tag_change(
          image,
          attribution,
          added_tags,
          removed_tags
        )
    end)
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
    |> Repo.transaction()
    |> case do
      {:ok, %{image: {image, _added, _removed}}} = res ->
        update_tag_change_limits_after_commit(image, attribution)

        res

      err ->
        err
    end
  end

  @doc """
  Updates the locked tags on an image.

  Locked tags can only be added or removed by privileged users.

  ## Examples

      iex> update_locked_tags(image, %{tag_input: "safe, validated"})
      {:ok, %Image{}}

  """
  def update_locked_tags(%Image{} = image, attrs) do
    new_tags = Tags.get_or_create_tags(attrs["tag_input"])

    image
    |> Repo.preload(:locked_tags)
    |> Image.locked_tags_changeset(attrs, new_tags)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Migrates source URLs from one image to another.

  This function is used during image merging to combine source URLs from both images.
  It will:

  1. Combine sources from both images
  2. Remove duplicates
  3. Take up to 15 sources (the system limit)
  4. Update the target image with the combined sources

  Returns the result of updating the target image with the combined sources.

  ## Parameters
  - source: The source image containing sources to migrate
  - target: The target image to receive the combined sources

  ## Examples

      iex> migrate_sources(source_image, target_image)
      {:ok, %Image{}}

  """
  def migrate_sources(source, target) do
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
  def change_image(%Image{} = image) do
    Image.changeset(image, %{})
  end

  @doc """
  Gets the tag list for a single image.
  """
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

      iex> load_image_index(scope)
      %Scrivener.Page{}

  """
  @spec load_image_index(Scope.t()) :: Scrivener.Page.t()
  def load_image_index(scope) do
    {definition, _tags} = ImageSearch.default_query(scope)

    ImageSearch.execute(definition)
  end

  @doc """
  Returns the paginated approval queue for `actor`: unapproved images, oldest
  first, with the listing preloads.

  Authorizes `:approve` against the image model. Returns `{:ok, images}` as a
  `m:Scrivener.Page` or `{:error, :unauthorized}`.

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
  Runs the search the scope's "q" parameter describes for the viewer.

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

      iex> search_images(scope)
      {:ok, %{images: %Scrivener.Page{}, tags: [%Tag{}]}}

      iex> search_images(bad_query_scope)
      {:error, "There was an error parsing your query."}

  """
  @spec search_images(Scope.t(), Keyword.t()) ::
          {:ok, %{images: Scrivener.Page.t(), tags: [Tag.t()]}} | {:error, String.t()}
  def search_images(scope, opts \\ []) do
    execute_opts =
      case Keyword.fetch(opts, :preload) do
        {:ok, preloads} -> [queryable: preload(Image, ^preloads)]
        :error -> []
      end
      |> Keyword.put(:hits, Keyword.get_lazy(opts, :hits, fn -> custom_ordering?(scope) end))

    with {:ok, {definition, tags}} <-
           ImageSearch.search_string(scope, scope.params["q"]) do
      images = ImageSearch.execute(definition, execute_opts)

      {:ok, %{images: images, tags: tags}}
    end
  end

  defp custom_ordering?(%{params: %{"sf" => sf}}) when sf not in ~W(id first_seen_at), do: true
  defp custom_ordering?(_scope), do: false

  @doc """
  Loads the non-hidden image named by `id`, with its uploader, sources, and
  tags preloaded.

  `id` is the id string, or `nil` when no image was named. A missing or
  malformed `id`, a well-formed id out of the valid range, an unknown id, and
  a hidden image are all `{:error, :not_found}`.

  ## Examples

      iex> load_public_image("1")
      {:ok, %Image{}}

      iex> load_public_image(nil)
      {:error, :not_found}

  """
  @spec load_public_image(IntegerId.integer_id() | nil) :: {:ok, Image.t()} | {:error, :not_found}
  def load_public_image(nil), do: {:error, :not_found}

  def load_public_image(id) when is_binary(id) do
    with {:ok, id} <- IntegerId.parse(id),
         %Image{} = image <-
           Image
           |> where(id: ^id, hidden_from_users: false)
           |> preload([:user, :sources, tags: :aliases])
           |> Repo.one() do
      {:ok, image}
    else
      _nil_or_error -> {:error, :not_found}
    end
  end

  @doc """
  Runs the "my:watched" search for the viewer scope, with the watched-feed
  preloads, and returns the record page.

  ## Examples

      iex> watched_images(scope)
      %Scrivener.Page{}

  """
  @spec watched_images(Scope.t()) :: Scrivener.Page.t()
  def watched_images(scope) do
    {:ok, {definition, _tags}} = ImageSearch.search_string(scope, "my:watched")

    Search.search_records(definition, preload(Image, [:sources, tags: :aliases]))
  end

  @doc """
  Loads the image named by `id` for showing, on behalf of `actor`.

  The image carries its preloads plus these counts: distinct tag changes, tags
  touched by those changes, and source changes. Viewing needs no permission - a
  hidden image is still returned - but an image merged into a duplicate is only
  shown to viewers permitted to `:show` it; anyone else gets
  `{:duplicate_of, image}` so the caller can act on `image.duplicate_id`. A
  malformed or unknown id is `{:error, :not_found}`.

  ## Examples

      iex> load_image_for_show(actor, "1")
      {:ok, %{image: %Image{}, tag_change_count: 2, tag_change_tag_count: 5, source_change_count: 1}}

      iex> load_image_for_show(actor, "bad")
      {:error, :not_found}

  """
  @spec load_image_for_show(Actor.t(), IntegerId.integer_id()) ::
          {:ok,
           %{
             image: Image.t(),
             tag_change_count: non_neg_integer(),
             tag_change_tag_count: non_neg_integer(),
             source_change_count: non_neg_integer()
           }}
          | {:duplicate_of, Image.t()}
          | {:error, :not_found}
  def load_image_for_show(%Actor{user: user}, id) do
    case IntegerId.parse(id) do
      {:ok, id} -> fetch_image_for_show(user, id)
      :error -> {:error, :not_found}
    end
  end

  defp fetch_image_for_show(user, id) do
    Image
    |> from(as: :image)
    |> where(id: ^id)
    |> join(
      :inner_lateral,
      [],
      subquery(
        TagChange
        |> where(image_id: parent_as(:image).id)
        |> join(:left, [c], t in assoc(c, :tags))
        |> select([c, t], %{
          change_count: count(c, :distinct),
          tag_count: count(t)
        })
      ),
      on: true
    )
    |> join(
      :inner_lateral,
      [],
      subquery(
        SourceChange
        |> where(image_id: parent_as(:image).id)
        |> select(%{count: count()})
      ),
      on: true
    )
    |> preload([:deleter, :locked_tags, :sources, user: [awards: :badge], tags: :aliases])
    |> select([i, t, s], {i, t.change_count, t.tag_count, s.count})
    |> Repo.one()
    |> case do
      nil ->
        {:error, :not_found}

      {image, tag_change_count, tag_change_tag_count, source_change_count} ->
        if not is_nil(image.duplicate_id) and not Canada.Can.can?(user, :show, image) do
          {:duplicate_of, image}
        else
          {:ok,
           %{
             image: image,
             tag_change_count: tag_change_count,
             tag_change_tag_count: tag_change_tag_count,
             source_change_count: source_change_count
           }}
        end
    end
  end

  @doc """
  Assembles the `ImagePage` for `actor`: the visible page of comments,
  the viewer's subscription state, their galleries paired with membership of
  this image, their interactions, and changesets for adding a comment and
  editing its metadata.

  Clears the viewer's notification for the image as a side effect, so the
  caller must read any notification counts afterwards. `comment_scrivener`
  is the `page`/`page_size` keyword list; viewers who read oldest-first and
  prefer jumping to the newest comments land on the last page unless they
  asked for a specific one.

  ## Examples

      iex> load_image_page(actor, image, page: 1, page_size: 25)
      %ImagePage{}

  """
  @spec load_image_page(Actor.t(), Image.t(), Keyword.t()) :: ImagePage.t()
  def load_image_page(%Actor{user: user} = actor, %Image{} = image, comment_scrivener) do
    clear_image_notification(image, user)

    comment_scrivener = maybe_jump_to_last_page(user, image, comment_scrivener)

    %ImagePage{
      image: image,
      comments: Comments.paginate_image_comments(actor, image, comment_scrivener),
      watching: subscribed?(image, user),
      user_galleries: Galleries.user_image_galleries(user, image),
      interactions: Interactions.user_interactions([image], user),
      # TODO: this should probably be actor-gated, so actors who can't currently interact
      # with the image don't receive changesets.
      comment_changeset: Comments.change_comment(%Comment{}),
      image_changeset: change_image(%{image | sources: sources_for_edit(image.sources)})
    }
  end

  defp maybe_jump_to_last_page(
         %{comments_newest_first: false, comments_always_jump_to_last: true} = user,
         image,
         scrivener
       ) do
    Keyword.merge(scrivener, page: Comments.last_comment_page(user, image, scrivener))
  end

  defp maybe_jump_to_last_page(_user, _image, scrivener), do: scrivener

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
  @spec load_new_image(Actor.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :ban}
  def load_new_image(%Actor{} = actor) do
    with :ok <- verify_not_banned(actor) do
      {:ok, change_image(%Image{sources: [%Source{}]})}
    end
  end

  @image_create_window 5

  @doc """
  Uploads a new image on behalf of `actor`, who must pass the write-access
  check: banned actors get `{:error, :ban}` and actors without a fingerprint
  `{:error, :unauthorized}`. A non-exempt actor who has uploaded within the last
  5 seconds gets `{:error, :rate_limited}`.

  On success the image row exists and processing continues in the
  background; see `create_image/2` for the result shape and failure tuples.

  ## Examples

      iex> upload_image(actor, %{"image" => upload, "tag_input" => "safe"})
      {:ok, %{image: %Image{}, upload_pid: pid}}

      iex> upload_image(banned_actor, params)
      {:error, :ban}

  """
  @spec upload_image(Actor.t(), map() | nil) ::
          {:ok, image_upload()}
          | {:error, :ban}
          | {:error, :unauthorized}
          | {:error, :rate_limited}
          | Ecto.Multi.failure()
  def upload_image(%Actor{} = actor, params) do
    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :image_create),
         {:ok, result} <- create_image(actor_attributes(actor), params) do
      RateLimiter.record_action(actor, :image_create, @image_create_window)
      {:ok, result}
    end
  end

  defp actor_attributes(%Actor{ip: ip, fingerprint: fingerprint, user: user}),
    do: [ip: ip, fingerprint: fingerprint, user: user]

  @doc """
  Finds the image adjacent to the one `image_id` names in the listing the
  scope's parameters describe, for prev/next navigation on behalf of the
  scope's viewer.

  The image is loaded by id and authorized for `:show`: a non-castable id is
  `{:error, :not_found}`, and an unknown id authorizes `nil`, which no
  ordinary rule permits, so it is `{:error, :unauthorized}`. The scope's "q"
  parameter (blank means everything) is compiled for the viewer; a malformed
  query crashes, as navigation never supplies one.

  Returns `{:ok, {image, {adjacent, hit}}}` - the hit carries the sort cursor
  for the caller to reuse - or `{:ok, {image, nil}}` at the end of the sequence.

  ## Examples

      iex> find_consecutive_image(scope, "42")
      {:ok, {%Image{}, {%Image{}, %{"sort" => [...]}}}}

  """
  @spec find_consecutive_image(Scope.t(), IntegerId.integer_id()) ::
          {:ok, {Image.t(), {Image.t(), map()} | nil}}
          | {:error, :unauthorized | :not_found}
  def find_consecutive_image(scope, image_id) do
    with {:ok, image} <- load_image_for_navigation(scope.user, image_id) do
      {:ok, {image, ImageSearch.find_consecutive(scope, image, navigation_query(scope))}}
    end
  end

  @doc """
  Returns the 1-based page number (as a string) on which the image `image_id`
  names appears when all images are listed by descending id, on behalf of the
  scope's viewer.

  Loading and authorization follow `find_consecutive_image/2`.

  ## Examples

      iex> find_image_index_page(scope, "42")
      {:ok, "3"}

  """
  @spec find_image_index_page(Scope.t(), IntegerId.integer_id()) ::
          {:ok, String.t()} | {:error, :unauthorized | :not_found}
  def find_image_index_page(scope, image_id) do
    with {:ok, image} <- load_image_for_navigation(scope.user, image_id) do
      pagination = %{scope.pagination | page_number: 1}

      {definition, _tags} =
        ImageSearch.query(scope, %{range: %{id: %{gt: image.id}}}, pagination: pagination)

      images = ImageSearch.execute(definition, queryable: Image)

      {:ok, page_for_offset(pagination.page_size, images.total_entries)}
    end
  end

  defp page_for_offset(per_page, offset) do
    offset
    |> div(per_page)
    |> Kernel.+(1)
    |> to_string()
  end

  defp navigation_query(scope) do
    {:ok, query} =
      scope.params["q"]
      |> match_all_if_blank()
      |> ImageQuery.compile(user: scope.user)

    query
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
  Loads images related to the one `image_id` names - sharing its
  lowest-population tags, weighted towards its most distinctive ones and the
  favers it has in common - on behalf of the scope's viewer.

  Loading and authorization follow `find_consecutive_image/2`; the image
  carries the faves, sources, and tags the scoring reads.

  Returns `{:ok, {image, images}}` with the related images scored best-first.

  ## Examples

      iex> related_images(scope, "42")
      {:ok, {%Image{}, %Scrivener.Page{}}}

  """
  @spec related_images(Scope.t(), IntegerId.integer_id()) ::
          {:ok, {Image.t(), Scrivener.Page.t()}} | {:error, :unauthorized | :not_found}
  def related_images(scope, image_id) do
    with {:ok, image} <-
           load_image_for_navigation(scope.user, image_id, [:faves, :sources, tags: :aliases]) do
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

  Returns the id, or `nil` when nothing matches or the query is malformed.

  ## Examples

      iex> random_image_id(scope)
      42

  """
  @spec random_image_id(Scope.t()) :: integer() | nil
  def random_image_id(scope) do
    result =
      ImageSearch.search_string(
        scope,
        Map.get(scope.params, "q", "*"),
        pagination: %{page_size: 1},
        sorts: &ImageSearch.parse_sort(%{"sf" => "random"}, &1)
      )

    case result do
      {:ok, {definition, _tags}} ->
        definition
        |> ImageSearch.execute(queryable: Image)
        |> Enum.to_list()
        |> case do
          [image] -> image.id
          [] -> nil
        end

      _error ->
        nil
    end
  end

  defp load_image_for_navigation(user, image_id, preloads \\ []) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(preload(Image, ^preloads), id),
         :ok <- authorize(user, :show, image),
         %Image{} <- image do
      {:ok, image}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      # Non-castable id, or a `nil` load the viewer was permitted to see.
      shape when shape in [:error, nil] -> {:error, :not_found}
    end
  end

  @doc """
  Loads the image named by `image_id`, applying `preloads`, and authorizes
  `actor` for `:show` on it.

  A well-formed id that names no row is authorized as `nil` - which no rule
  permits - so it is `{:error, :unauthorized}`; an id that no `integer` column
  could hold is `{:error, :not_found}`.

  Returns `{:ok, image}`, `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> load_visible_image(actor, "1")
      {:ok, %Image{}}

      iex> load_visible_image(actor, "999999999")
      {:error, :unauthorized}

  """
  @spec load_visible_image(Actor.t(), IntegerId.integer_id(), list()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def load_visible_image(actor, image_id, preloads \\ []) do
    case IntegerId.parse(image_id) do
      {:ok, id} ->
        image = Image |> preload(^preloads) |> Repo.get(id)

        with :ok <- authorize(actor, :show, image), do: {:ok, image}

      :error ->
        {:error, :not_found}
    end
  end

  @typedoc """
  Result of the `create_image/3` function. The image was created in a DB but an
  upload process could still running in the background with its PID given in the
  `upload_pid` field.
  """
  @type image_upload :: %{
          image: %Image{},
          upload_pid: pid
        }

  @doc """
  Preloads the tag aliases on a freshly created image for the public API.

  ## Examples

      iex> preload_created_image(image)
      %Image{}

  """
  @spec preload_created_image(Image.t()) :: Image.t()
  def preload_created_image(image) do
    Repo.preload(image, tags: :aliases)
  end

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

  @doc """
  Approves the image named by `image_id` for public viewing, on behalf of
  `actor`.

  The image is loaded by id and authorized for `:approve`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:approve` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. An image that is already approved is
  `{:error, :already_approved}` and is left untouched. On success the image is
  made visible, statistics are updated, the image is reindexed, and a moderation
  log is written attributing the approval to `actor`.

  Returns `{:ok, image}` with the approved image.

  ## Examples

      iex> approve_image(moderator, "42")
      {:ok, %Image{}}

      iex> approve_image(user, "42")
      {:error, :unauthorized}

  """
  @spec approve_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found | :already_approved}
  def approve_image(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :approve, image),
         %Image{approved: false} <- image do
      {:ok, image} = approve_image(image)

      ModerationLogs.create_moderation_log(
        actor,
        "Image.Approve:create",
        Paths.image_path(image),
        "Approved image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      %Image{approved: true} -> {:error, :already_approved}
    end
  end

  defp maybe_approve_image(_image, nil), do: false

  defp maybe_approve_image(_image, %User{verified: false, role: role}) when role == "user",
    do: false

  defp maybe_approve_image(image, _user), do: approve_image(image)

  defp increment_user_stats(nil), do: false

  defp increment_user_stats(%User{} = user) do
    UserStatistics.inc_stat(user, :images_count)
  end

  defp maybe_suggest_user_verification(%User{id: id, images_count: 5, verified: false}) do
    Reports.create_system_report(
      {"User", id},
      "Verification",
      "User has uploaded enough approved images to be considered for verification."
    )
  end

  defp maybe_suggest_user_verification(_user), do: false

  @doc """
  Counts the number of images pending approval that a user can moderate.

  ## Examples

      iex> count_pending_approvals(admin)
      42

      iex> count_pending_approvals(user)
      nil

  """
  def count_pending_approvals(user) do
    if Canada.Can.can?(user, :approve, %Image{}) do
      Image
      |> where(approved: false)
      |> Repo.aggregate(:count)
    else
      nil
    end
  end

  @doc """
  Marks the given already-loaded image as the current featured image.

  This is the internal feature engine; it performs no authorization and writes
  no moderation log, so callers needing those go through `feature_image/2`.

  ## Examples

      iex> feature_loaded_image(user, image)
      {:ok, %ImageFeature{}}

  """
  def feature_loaded_image(featurer, %Image{} = image) do
    %ImageFeature{user_id: featurer.id, image_id: image.id}
    |> ImageFeature.changeset(%{})
    |> Repo.insert()
  end

  @doc """
  Marks the image named by `image_id` as the current featured image, on behalf
  of `actor`.

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. A deleted image (hidden from users) cannot be
  featured and is `{:error, :deleted}`, left untouched. On success the feature
  is recorded and a moderation log is written attributing it to `actor`.

  Returns `{:ok, feature}` with the created feature.

  ## Examples

      iex> feature_image(moderator, "42")
      {:ok, %ImageFeature{}}

      iex> feature_image(user, "42")
      {:error, :unauthorized}

  """
  @spec feature_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, ImageFeature.t()} | {:error, :unauthorized | :not_found | :deleted}
  def feature_image(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{hidden_from_users: false} <- image,
         {:ok, feature} <- feature_loaded_image(actor.user, image) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.Feature:create",
        Paths.image_path(image),
        "Featured image #{image.id}"
      )

      {:ok, feature}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      %Image{hidden_from_users: true} -> {:error, :deleted}
    end
  end

  @doc """
  Hard-deletes the contents of the image named by `image_id`, on behalf of
  `actor`, purging its stored file and thumbnails.

  The image is loaded by id and authorized for `:destroy` - a capability plain
  moderators lack (it requires an Image-admin role grant or the admin role). A
  non-castable or out-of-range id is `{:error, :not_found}`. A well-formed but
  unknown id is authorized as a `nil` load: an actor who may not `:destroy` it
  gets `{:error, :unauthorized}`, while an actor permitted to act on the `nil`
  load gets `{:error, :not_found}`. Only an already-deleted image (hidden from
  users) may be destroyed; a still-visible image is `{:error, :not_deleted}`,
  left untouched. On success the file and thumbnails are purged and a moderation
  log is written attributing the destruction to `actor`.

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
          | {:error, :unauthorized | :not_found | :not_deleted | Ecto.Changeset.t()}
  def destroy_image(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :destroy, image),
         %Image{hidden_from_users: true} <- image,
         {:ok, image} <- destroy_image(image) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.Destroy:create",
        Paths.image_path(image),
        "Hard-deleted image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      %Image{hidden_from_users: false} -> {:error, :not_deleted}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  Locks (`locked?` true) or unlocks (`locked?` false) comments on the image
  named by `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. On success commenting is toggled, the image is
  reindexed, and a moderation log is written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> set_comment_locked(moderator, "42", true)
      {:ok, %Image{}}

      iex> set_comment_locked(user, "42", true)
      {:error, :unauthorized}

  """
  @spec set_comment_locked(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def set_comment_locked(%Actor{} = actor, image_id, locked?) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- lock_comments(image, locked?) do
      {log_type, log_body} =
        if locked? do
          {"Image.CommentLock:create", "Locked comments on image #{image.id}"}
        else
          {"Image.CommentLock:delete", "Unlocked comments on image #{image.id}"}
        end

      ModerationLogs.create_moderation_log(actor, log_type, Paths.image_path(image), log_body)

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Locks (`locked?` true) or unlocks (`locked?` false) description editing on the
  image named by `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. On success description editing is toggled, the
  image is reindexed, and a moderation log is written attributing the change to
  `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> set_description_locked(moderator, "42", true)
      {:ok, %Image{}}

      iex> set_description_locked(user, "42", true)
      {:error, :unauthorized}

  """
  @spec set_description_locked(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def set_description_locked(%Actor{} = actor, image_id, locked?) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- lock_description(image, locked?) do
      {log_type, log_body} =
        if locked? do
          {"Image.DescriptionLock:create", "Locked description editing on image #{image.id}"}
        else
          {"Image.DescriptionLock:delete", "Unlocked description editing on image #{image.id}"}
        end

      ModerationLogs.create_moderation_log(actor, log_type, Paths.image_path(image), log_body)

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Locks (`locked?` true) or unlocks (`locked?` false) tag editing on the image
  named by `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. On success tag editing is toggled, the image is
  reindexed, and a moderation log is written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> set_tag_locked(moderator, "42", true)
      {:ok, %Image{}}

      iex> set_tag_locked(user, "42", true)
      {:error, :unauthorized}

  """
  @spec set_tag_locked(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def set_tag_locked(%Actor{} = actor, image_id, locked?) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- lock_tags(image, locked?) do
      {log_type, log_body} =
        if locked? do
          {"Image.TagLock:create", "Locked tags on image #{image.id}"}
        else
          {"Image.TagLock:delete", "Unlocked tags on image #{image.id}"}
        end

      ModerationLogs.create_moderation_log(actor, log_type, Paths.image_path(image), log_body)

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Clears the original SHA-512 hash of the image named by `image_id`, on behalf
  of `actor`, allowing the same file to be uploaded again.

  The image is loaded by id and the `:hide` permission is checked before it is
  modified. A non-castable or out-of-range id is `{:error, :not_found}`. A
  well-formed but unknown id is authorized as a `nil` load: an actor who may not
  `:hide` it gets `{:error, :unauthorized}`, while an actor permitted to act on
  the `nil` load gets `{:error, :not_found}`. On success the hash is cleared, the
  image is reindexed, and a moderation log is written attributing the change to
  `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> remove_image_hash(moderator, "42")
      {:ok, %Image{}}

      iex> remove_image_hash(user, "42")
      {:error, :unauthorized}

  """
  @spec remove_image_hash(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def remove_image_hash(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- remove_hash(image) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.Hash:delete",
        Paths.image_path(image),
        "Cleared hash of image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Loads the image named by `image_id` for moderation, on behalf of `actor`.

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`.

  Returns `{:ok, image}` with the loaded image, carrying the associations
  named by `opts[:preload]` (none by default).

  ## Examples

      iex> load_hidable_image(moderator, "42")
      {:ok, %Image{}}

      iex> load_hidable_image(user, "42")
      {:error, :unauthorized}

  """
  @spec load_hidable_image(Actor.t(), IntegerId.integer_id(), Keyword.t()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def load_hidable_image(%Actor{} = actor, image_id, opts \\ []) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image do
      {:ok, Repo.preload(image, Keyword.get(opts, :preload, []))}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Updates the moderation notes on the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with a `"scratchpad"` key).

  The image is loaded by id and authorized for `:hide` before it is modified. A
  non-castable or out-of-range id is `{:error, :not_found}`. A well-formed but
  unknown id is authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. A blank value clears the notes. On success the
  notes are updated, the image is reindexed, and a moderation log is written
  attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> update_scratchpad(moderator, "42", %{"scratchpad" => "watch closely"})
      {:ok, %Image{}}

      iex> update_scratchpad(user, "42", %{"scratchpad" => "watch closely"})
      {:error, :unauthorized}

  """
  @spec update_scratchpad(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def update_scratchpad(%Actor{} = actor, image_id, attrs) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- update_scratchpad(image, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.Scratchpad:update",
        Paths.image_path(image),
        "Updated mod notes on image #{image.id} (#{image.scratchpad})"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Deletes the source change history of the image named by `image_id`, on behalf
  of `actor`.

  The image is loaded by id and the `:hide` permission is checked before it is
  modified. A non-castable or out-of-range id is `{:error, :not_found}`. A
  well-formed but unknown id is authorized as a `nil` load: an actor who may not
  `:hide` it gets `{:error, :unauthorized}`, while an actor permitted to act on
  the `nil` load gets `{:error, :not_found}`. On success the source history is
  removed, the image is reindexed, and a moderation log is written attributing
  the deletion to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> remove_source_history(moderator, "42")
      {:ok, %Image{}}

      iex> remove_source_history(user, "42")
      {:error, :unauthorized}

  """
  @spec remove_source_history(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def remove_source_history(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- remove_source_history(image) do
      reindex_image(image)

      ModerationLogs.create_moderation_log(
        actor,
        "Image.SourceHistory:delete",
        Paths.image_path(image),
        "Deleted source history for image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Repairs the image named by `image_id`, on behalf of `actor`, by regenerating
  its thumbnails and purging its cached files.

  The image is loaded by id and the `:hide` permission is checked before any
  work is enqueued. A non-castable or out-of-range id is `{:error, :not_found}`.
  A well-formed but unknown id is authorized as a `nil` load: an actor who may
  not `:hide` it gets `{:error, :unauthorized}`, while an actor permitted to act
  on the `nil` load gets `{:error, :not_found}`. On success the thumbnail
  regeneration job is enqueued, the image's CDN files are purged, and a
  moderation log is written attributing the repair to `actor`.

  Returns `{:ok, image}` with the loaded image.

  ## Examples

      iex> repair_image(moderator, "42")
      {:ok, %Image{}}

      iex> repair_image(user, "42")
      {:error, :unauthorized}

  """
  @spec repair_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def repair_image(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image do
      repair_image(image)
      purge_files(image, image.hidden_image_key)

      ModerationLogs.create_moderation_log(
        actor,
        "Image.Repair:create",
        Paths.image_path(image),
        "Repaired image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Repairs an image by regenerating its thumbnails.
  Returns the image struct unchanged, for use in a pipeline.

  This will:
  1. Mark the image as needing thumbnail regeneration
  2. Queue the thumbnail generation job

  ## Examples

      iex> repair_image(image)
      %Image{}

  """
  def repair_image(%Image{} = image) do
    Image
    |> where(id: ^image.id)
    |> Repo.update_all(set: [thumbnails_generated: false, processed: false])

    Exq.enqueue(Exq, queue(image.image_mime_type), ThumbnailWorker, [image.id])

    image
  end

  defp queue("video/webm"), do: "videos"
  defp queue(_mime_type), do: "images"

  @doc """
  Replaces the file content of the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with an `"image"` upload).

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. A deleted image (hidden from users) cannot be
  replaced and is `{:error, :deleted}`, left untouched. On success the file is
  replaced, thumbnails are regenerated, old files are purged, the image is
  reindexed, and a moderation log is written attributing the change to `actor`.

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
          {:ok, Image.t()} | {:error, :unauthorized | :not_found | :deleted | Ecto.Changeset.t()}
  def update_file(%Actor{} = actor, image_id, attrs) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{hidden_from_users: false} <- image,
         {:ok, image} <- update_file(image, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.File:update",
        Paths.image_path(image),
        "Updated file of image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      %Image{hidden_from_users: true} -> {:error, :deleted}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  Updates the description of the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with a `"description"` key).

  Banned actors are rejected first with `{:error, :ban}` (a write with no
  fingerprint is `{:error, :unauthorized}`), before the image is loaded, so the
  ban decision does not depend on the id. The image is then loaded by id and
  authorized for `:edit_description` - the uploader may edit a non-hidden image
  whose description editing is allowed, and staff may edit any image. A
  non-castable or out-of-range id is `{:error, :not_found}`. A well-formed but
  unknown id is authorized as a `nil` load: an actor who may not
  `:edit_description` it gets `{:error, :unauthorized}`, while an actor permitted
  to act on the `nil` load gets `{:error, :not_found}`.

  Returns `{:ok, {image, old_description}}` with the updated image (its author,
  sources, and tags preloaded) and the description it replaced
  (needed to broadcast the change), or `{:error, %Ecto.Changeset{}}` when the new
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
         {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(preload(Image, [:user, :sources, tags: :aliases]), id),
         :ok <- authorize(actor, :edit_description, image),
         %Image{description: old_description} <- image,
         {:ok, image} <- update_description(image, attrs) do
      {:ok, {image, old_description}}
    else
      {:error, :ban} -> {:error, :ban}
      {:error, :unauthorized} -> {:error, :unauthorized}
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, %Ecto.Changeset{}} = error -> error
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
  sources, and tags preloaded) and authorized for `:edit_metadata` - editable on
  a non-hidden image by anyone (anonymous included), so a hidden image is
  `{:error, :unauthorized}`. A non-castable or out-of-range id is
  `{:error, :not_found}`; a well-formed but unknown id is authorized as a `nil`
  load, normally `{:error, :unauthorized}`. On success the sources are updated and
  attributed, the actor's metadata-update stat is incremented when sources
  actually changed, and the image is reindexed.

  Returns `{:ok, %{image: image, added: added_sources, removed: removed_sources,
  source_change_count: count}}` - everything the caller needs to broadcast the
  change - or `{:error, %Ecto.Changeset{}}` when
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
    attribution = [ip: actor.ip, fingerprint: actor.fingerprint, user: actor.user]

    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :source_update),
         {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(preload(Image, [:user, :sources, tags: :aliases]), id),
         :ok <- authorize(actor, :edit_metadata, image),
         %Image{} <- image,
         {:ok, %{image: {image, added, removed}}} <-
           update_loaded_sources(image, attribution, attrs) do
      if Enum.any?(added) or Enum.any?(removed) do
        UserStatistics.inc_stat(actor.user, :metadata_updates_count)
      end

      reindex_image(image)
      RateLimiter.record_action(actor, :source_update, @source_update_window)

      {:ok,
       %{
         image: image,
         added: added,
         removed: removed,
         source_change_count: SourceChanges.count_for_image(image.id)
       }}
    else
      {:error, :ban} -> {:error, :ban}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, :rate_limited} -> {:error, :rate_limited}
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :image, changeset, _changes} -> {:error, changeset}
    end
  end

  defp source_change_attributes(attribution, image, source, added, user) do
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
      ip: attribution[:ip],
      fingerprint: attribution[:fingerprint],
      added: added
    }
  end

  @doc """
  Updates the locked tag list of the image named by `image_id`, on behalf of
  `actor`, from `attrs` (a map with a `"tag_input"` key).

  The image is loaded by id and authorized for `:hide` before it is modified. A
  non-castable or out-of-range id is `{:error, :not_found}`. A well-formed but
  unknown id is authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. A blank `tag_input` clears the list. On success
  the locked tags are replaced, the image is reindexed, and a moderation log is
  written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> update_locked_tags(moderator, "42", %{"tag_input" => "safe, solo"})
      {:ok, %Image{}}

      iex> update_locked_tags(user, "42", %{"tag_input" => "safe, solo"})
      {:error, :unauthorized}

  """
  @spec update_locked_tags(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def update_locked_tags(%Actor{} = actor, image_id, attrs) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- update_locked_tags(image, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.TagLock:update",
        Paths.image_path(image),
        "Updated list of locked tags on image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
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
  disabled is `{:error, :unauthorized}`. A non-castable or out-of-range id is
  `{:error, :not_found}`; a well-formed but unknown id is authorized as a `nil`
  load, normally `{:error, :unauthorized}`. On success the tags are updated and
  attributed, the image, its comments, and the affected tags are reindexed, and
  the actor's metadata-update stat is incremented when tags actually changed.

  Returns `{:ok, %{image: image, added: added_tags, removed: removed_tags,
  tag_change_count: count, tag_change_tag_count: tag_count}}` - everything the
  caller needs to broadcast the change. Failure
  shapes: `{:error, %Ecto.Changeset{}}` when the update is rejected (e.g. the
  image would drop below the minimum tag count), `{:error, :update_failed}` for
  any other rollback, or `{:error, :rate_limited}` from either of two independent
  counters - the once-per-window check above (`rl:tag_update:*`), or the
  in-transaction `TagChanges.Limits` check that caps the number of tag and rating
  changes over ten minutes (`rltcn:`/`rltcr:`) and rolls back at the
  `:check_limits` step. All failures leave the image untouched.

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
    attribution = [ip: actor.ip, fingerprint: actor.fingerprint, user: actor.user]

    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :tag_update),
         {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(preload(Image, [:user, :locked_tags, :sources, tags: :aliases]), id),
         :ok <- authorize(actor, :edit_metadata, image),
         %Image{} <- image,
         {:ok, %{image: {image, added, removed}}} <-
           update_loaded_tags(image, attribution, attrs) do
      Comments.reindex_comments_on_image(image)
      reindex_image(image)
      Tags.reindex_tags(added ++ removed)

      if Enum.any?(added ++ removed) do
        UserStatistics.inc_stat(actor.user, :metadata_updates_count)
      end

      RateLimiter.record_action(actor, :tag_update, @tag_update_window)

      {tag_change_count, tag_change_tag_count} = TagChanges.count_tag_changes(:image_id, image.id)

      {:ok,
       %{
         image: Repo.preload(image, [:sources, tags: :aliases], force: true),
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
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :image, changeset, _changes} -> {:error, changeset}
      {:error, :check_limits, _value, _changes} -> {:error, :rate_limited}
      _other -> {:error, :update_failed}
    end
  end

  defp check_tag_change_limits_before_commit(image, attribution) do
    tag_changed_count = length(image.added_tags) + length(image.removed_tags)
    rating_changed = image.ratings_changed
    user = attribution[:user]
    ip = attribution[:ip]

    cond do
      Limits.limited_for_tag_count?(user, ip, tag_changed_count) ->
        {:error, :limit_exceeded}

      rating_changed and Limits.limited_for_rating_count?(user, ip) ->
        {:error, :limit_exceeded}

      true ->
        {:ok, 0}
    end
  end

  @doc """
  Updates the tag change tracking after committing updates to an image.

  This updates the rate limit counters for total tag change count and rating change count
  based on the changes made to the image.

  ## Examples

      iex> update_tag_change_limits_after_commit(image, %{user: user, ip: "127.0.0.1"})
      :ok

  """
  def update_tag_change_limits_after_commit(image, attribution) do
    rating_changed_count = if(image.ratings_changed, do: 1, else: 0)
    tag_changed_count = length(image.added_tags) + length(image.removed_tags)
    user = attribution[:user]
    ip = attribution[:ip]

    :ok = Limits.update_tag_count_after_update(user, ip, tag_changed_count)
    :ok = Limits.update_rating_count_after_update(user, ip, rating_changed_count)
    :ok
  end

  @doc """
  Reassigns the uploader of the image named by `image_id`, on behalf of `actor`,
  from `image_params` (a map with a `"username"` key; a
  blank username clears the uploader, anonymizing it).

  Authorization is `:show` on `:ip_address` - a moderator-and-above capability -
  and is checked before the image is loaded, so an actor without it gets
  `{:error, :unauthorized}` regardless of the id. The image is then loaded by id
  with no per-image authorization: a non-castable, out-of-range, or unknown id is
  `{:error, :not_found}`. On success the uploader is reassigned, the image is
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
          | {:error, :unauthorized | :not_found | :invalid_params | Ecto.Changeset.t()}
  def update_uploader(%Actor{} = actor, image_id, image_params) do
    with :ok <- authorize(actor, :show, :ip_address),
         {:ok, id} <- IntegerId.parse(image_id),
         %Image{} = image <- Repo.get(Image, id),
         true <- is_map(image_params),
         {:ok, image} <- update_uploader(image, image_params) do
      reindex_image(image)
      image = Repo.preload(image, user: [awards: :badge])

      ModerationLogs.create_moderation_log(
        actor,
        "Image.Uploader:update",
        Paths.image_path(image),
        "Changed uploader of image #{image.id}"
      )

      {:ok, image}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      # Non-castable/out-of-range id, or an unknown id (loaded with no per-image
      # authorization, so it is a plain not-found rather than unauthorized).
      shape when shape in [:error, nil] -> {:error, :not_found}
      false -> {:error, :invalid_params}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  Sets (`anonymous?` true) or clears (`anonymous?` false) the anonymity of the
  image named by `image_id`, on behalf of `actor`.

  Authorization is `:show` on `:ip_address` - a moderator-and-above capability -
  and is checked before the image is loaded, so an actor without it gets
  `{:error, :unauthorized}` regardless of the id. The image is then loaded by id
  with no per-image authorization: a non-castable, out-of-range, or unknown id is
  `{:error, :not_found}`. On success the anonymity is toggled, the image is
  reindexed, and a moderation log is written attributing the change to `actor`.

  Returns `{:ok, image}` with the updated image.

  ## Examples

      iex> update_anonymous(moderator, "42", true)
      {:ok, %Image{}}

      iex> update_anonymous(user, "42", true)
      {:error, :unauthorized}

  """
  @spec update_anonymous(Actor.t(), IntegerId.integer_id(), boolean()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def update_anonymous(%Actor{} = actor, image_id, anonymous?) do
    with :ok <- authorize(actor, :show, :ip_address),
         {:ok, id} <- IntegerId.parse(image_id),
         %Image{} = image <- Repo.get(Image, id),
         {:ok, image} <- update_anonymous(image, %{"anonymous" => anonymous?}) do
      reindex_image(image)

      log_type = if anonymous?, do: "Image.Anonymous:create", else: "Image.Anonymous:delete"

      ModerationLogs.create_moderation_log(
        actor,
        log_type,
        Paths.image_path(image),
        "Updated anonymity of image #{image.id}"
      )

      {:ok, image}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      # Non-castable/out-of-range id, or an unknown id (loaded with no per-image
      # authorization, so it is a plain not-found rather than unauthorized).
      shape when shape in [:error, nil] -> {:error, :not_found}
    end
  end

  @doc """
  Updates the deletion reason of the image named by `image_id`, on behalf of
  `actor`, from `attrs`.

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. Only an already-hidden image may have its reason
  changed; a visible image is `{:error, :not_deleted}`, left untouched. On success
  the reason is updated, the image is reindexed, and a moderation log is written
  attributing the change to `actor`.

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
          | {:error, :unauthorized | :not_found | :not_deleted | Ecto.Changeset.t()}
  def update_hide_reason(%Actor{} = actor, image_id, attrs) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{hidden_from_users: true} <- image,
         {:ok, image} <- update_hide_reason(image, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.Delete:update",
        Paths.image_path(image),
        "Changed deletion reason of #{image.id} (#{image.deletion_reason})"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      %Image{hidden_from_users: false} -> {:error, :not_deleted}
      {:error, %Ecto.Changeset{}} = error -> error
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

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. On success the image is hidden (its reports and
  duplicate reports closed, tag counts decremented, thumbnails purged, everything
  reindexed) and a moderation log is written attributing the deletion to `actor`.

  Returns `{:ok, image}` with the hidden image, or `{:error, :hide_failed}` when
  the hide is rejected (e.g. a blank deletion reason), leaving the image visible.

  ## Examples

      iex> hide_image(moderator, "42", %{"deletion_reason" => "Rule violation"})
      {:ok, %Image{}}

      iex> hide_image(user, "42", %{"deletion_reason" => "Rule violation"})
      {:error, :unauthorized}

  """
  @spec hide_image(Actor.t(), IntegerId.integer_id(), map()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found | :hide_failed}
  def hide_image(%Actor{} = actor, image_id, attrs) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, %{image: hidden}} <- hide_loaded_image(image, actor.user, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.Delete:create",
        Paths.image_path(hidden),
        "Deleted image #{hidden.id} (#{hidden.deletion_reason})"
      )

      {:ok, hidden}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, _op, _changeset, _changes} -> {:error, :hide_failed}
    end
  end

  @doc """
  Restores (unhides) the image named by `image_id` from moderation hiding, on
  behalf of `actor`.

  The image is loaded by id and authorized for `:hide`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:hide` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. Restoring an image that is not hidden still
  succeeds (it is left visible). On success the image is made visible again, its
  content reindexed, and a moderation log is written attributing the restore to
  `actor`.

  Returns `{:ok, image}` with the restored image.

  ## Examples

      iex> unhide_image(moderator, "42")
      {:ok, %Image{}}

      iex> unhide_image(user, "42")
      {:error, :unauthorized}

  """
  @spec unhide_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def unhide_image(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :hide, image),
         %Image{} <- image,
         {:ok, image} <- unhide_image(image) do
      ModerationLogs.create_moderation_log(
        actor,
        "Image.Delete:delete",
        Paths.image_path(image),
        "Restored image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Applies a batch tag edit to `image_ids` on behalf of `actor`, an
  `m:Philomena.Attribution.Actor`.

  Authorizes `:batch_update` against the tag model, parses the tag list into the
  added and removed tags (resolving aliases and implications for additions),
  splits the raw ids into castable integers and unparsable leftovers, and runs
  the batch through `batch_update/4`. Batch tagging is a staff surface and is
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

      case batch_update(image_ids, added_tags, removed_tags, attributes) do
        {:ok, matched_ids} ->
          # Ids which parsed but matched no existing, non-hidden image were
          # never touched by the batch, so they are reported as failed.
          unmatched_ids = image_ids -- matched_ids

          ModerationLogs.create_moderation_log(
            actor.user,
            "Admin.Batch.Tag:update",
            Paths.profile_path(actor.user),
            "Batch tagged '#{tag_list}' on #{Enum.count(matched_ids)} images"
          )

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
  def batch_update(image_ids, added_tags, removed_tags, attributes) do
    batch_update(
      Enum.map(image_ids, fn id ->
        %{
          image_id: id,
          added_tags: added_tags,
          removed_tags: removed_tags
        }
      end),
      attributes
    )
  end

  def batch_update(changes, attributes) do
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

      Repo.insert_all(TagChanges.Tag, added_changes ++ removed_changes)

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

      # Report the ids the batch actually matched back to the caller.
      image_ids
    end)
    |> case do
      {:ok, _} = result ->
        reindex_images(image_ids)
        Comments.reindex_comments_on_images(image_ids)
        Tags.reindex_tags(Enum.flat_map(changes, &(&1.added_tags ++ &1.removed_tags)))
        TagChanges.reindex_tag_changes_on_images(image_ids)

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

  # Generate data for TagChanges.Tag struct.
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
  def user_name_reindex(old_name, new_name) do
    data = Images.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Image, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Removes the vote cast by the user named by `user_id` on the image named by
  `image_id`, on behalf of `actor`.

  The image is loaded by id and authorized for `:tamper`; the target user is then
  loaded by id. A non-castable or out-of-range image id is `{:error, :not_found}`,
  and a well-formed but unknown image id is authorized as a `nil` load (an actor
  who may not `:tamper` gets `{:error, :unauthorized}`, one permitted to act on
  the `nil` load gets `{:error, :not_found}`). A non-castable or unknown user id
  is `{:error, :not_found}`, checked after image authorization. Removing a vote
  the user never cast still succeeds. On success the image is reindexed and a
  moderation log recording the removed vote type and target user is written.

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
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def delete_user_vote(%Actor{} = actor, image_id, user_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :tamper, image),
         %Image{} <- image,
         {:ok, user} <- load_vote_user(user_id) do
      {:ok, result} = Repo.transaction(ImageVotes.delete_vote_transaction(image, user))

      reindex_image(image)

      vote_type =
        case result do
          %{undownvote: {1, _}} -> "downvote"
          %{unupvote: {1, _}} -> "upvote"
          _ -> "vote"
        end

      ModerationLogs.create_moderation_log(
        actor,
        "Image.Tamper:create",
        Paths.image_path(image),
        "Deleted #{vote_type} by #{user.name} on image #{image.id}"
      )

      {:ok, image}
    else
      # Non-castable image id, an unknown image `nil` load the actor could act
      # on, or an unknown/non-castable user id.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  # The target user is loaded with no authorization: an unknown or non-castable
  # id is a plain not-found.
  defp load_vote_user(user_id) do
    with {:ok, id} <- IntegerId.parse(user_id),
         %User{} = user <- Repo.get(User, id) do
      {:ok, user}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Queues a single image for search index updates.
  Returns the image struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_image(image)
      %Image{}

  """
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
  Performs a search reindex operation on images matching the given criteria.

  ## Parameters
  - column: The database column to filter on (e.g., :id)
  - condition: A list of values to match against the column

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      :ok

  """
  def perform_reindex(column, condition) do
    Image
    |> preload(^indexing_preloads())
    |> where([i], field(i, ^column) in ^condition)
    |> Search.reindex(Image)
  end

  @doc """
  Purges image files from the CDN.

  Enqueues a job to purge both visible and hidden thumbnail paths for the given image.

  ## Examples

      iex> purge_files(image, "hidden_key")
      :ok

  """
  def purge_files(image, hidden_key) do
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
  Executes the actual purge operation for image files.

  Calls the system purge-cache command to remove the specified files from the CDN cache.

  ## Examples

      iex> perform_purge(["file1.jpg", "file2.jpg"])
      :ok

  """
  def perform_purge(files) do
    {_out, 0} = System.cmd("purge-cache", [JSON.encode!(%{files: files})])

    :ok
  end

  alias Philomena.Images.Subscription

  @doc """
  Migrates subscriptions and notifications from one image to another.

  This function is used during image merging to transfer all subscriptions
  and notifications from the source image to the target image. It handles:

  1. User subscriptions
  2. Comment notifications
  3. Merge notifications

  Returns `{:ok, {comment_notification_count, merge_notification_count}}`.

  ## Parameters

    - source: The source image to migrate from
    - target: The target image to migrate to

  ## Examples

      iex> migrate_subscriptions(source_image, target_image)
      {:ok, {5, 2}}

  """
  def migrate_subscriptions(source, target) do
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
    Notifications.create_image_merge_notification(target, source)
  end

  @doc """
  Subscribes `actor` to the image named by `image_id`, so they are notified of
  new comments on it.

  The image is loaded by id and authorized for `:show`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:show` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. Subscribing is idempotent.

  Returns `{:ok, image}`, or `{:error, %Ecto.Changeset{}}` if the subscription
  insert is rejected.

  ## Examples

      iex> subscribe_image(user, "42")
      {:ok, %Image{}}

      iex> subscribe_image(user, "999999999")
      {:error, :unauthorized}

  """
  @spec subscribe_image(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def subscribe_image(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :show, image),
         %Image{} <- image,
         {:ok, _subscription} <- create_subscription(image, actor.user) do
      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
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
          {:ok, Image.t()} | {:error, :unauthorized | :not_found}
  def unsubscribe_image(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :show, image),
         %Image{} <- image do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(image, actor.user)
      {:ok, image}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Records a personal hide of the image named by `image_id` for `actor`, so the
  image is filtered out of `actor`'s browsing. This is the per-user hide
  interaction, distinct from the moderator hide `hide_image/3`.

  Banned actors are rejected first with `{:error, :ban}` (a write with no
  fingerprint is `{:error, :unauthorized}`), before the image is loaded. The
  image is then loaded by id and authorized for `:vote`. A non-castable or
  out-of-range id is `{:error, :not_found}`; a well-formed but unknown id is
  authorized as a `nil` load, normally `{:error, :unauthorized}`. Hiding is
  idempotent (an existing hide is replaced).

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
      Multi.append(
        ImageHides.delete_hide_transaction(image, actor.user),
        ImageHides.create_hide_transaction(image, actor.user)
      )
      |> Repo.transaction()
      |> hide_result(image)
    end
  end

  @doc """
  Removes `actor`'s personal hide of the image named by `image_id`. This is the
  per-user unhide interaction, distinct from the moderator unhide `unhide_image/2`.

  Loading, authorization, and ban semantics mirror `create_image_hide/2`.
  Removing a hide that does not exist still succeeds.

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
      image
      |> ImageHides.delete_hide_transaction(actor.user)
      |> Repo.transaction()
      |> hide_result(image)
    end
  end

  # Shared loader for the per-user hide interaction: a banned actor is rejected
  # first, then the image is loaded by id and authorized for `:vote`.
  defp load_image_for_hide(actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :vote, image),
         %Image{} <- image do
      {:ok, image}
    else
      {:error, :ban} -> {:error, :ban}
      {:error, :unauthorized} -> {:error, :unauthorized}
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
    end
  end

  defp hide_result({:ok, _changes}, image), do: {:ok, get_image!(image.id) |> reindex_image()}
  defp hide_result(_error, _image), do: {:error, :hide_failed}

  @doc """
  Loads the image named by `image_id` for a fave or vote interaction by `actor`,
  with the sources and tags preloaded that the forced-filter check needs.

  Banned actors are rejected first with `{:error, :ban}` (a write with no
  fingerprint is `{:error, :unauthorized}`), before the image is loaded. The
  image is then loaded by id and authorized for `:vote`. A non-castable or
  out-of-range id is `{:error, :not_found}`; a well-formed but unknown id is
  authorized as a `nil` load, normally `{:error, :unauthorized}`.

  Returns `{:ok, image}`. Shared by the fave and vote paths, which run the
  forced-filter check on the result.

  ## Examples

      iex> load_image_for_interaction(actor, "42")
      {:ok, %Image{}}

  """
  @spec load_image_for_interaction(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_image_for_interaction(actor, image_id) do
    with :ok <- verify_write_access(actor),
         {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(preload(Image, [:sources, tags: :aliases]), id),
         :ok <- authorize(actor, :vote, image),
         %Image{} <- image do
      {:ok, image}
    else
      {:error, :ban} -> {:error, :ban}
      {:error, :unauthorized} -> {:error, :unauthorized}
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
    end
  end

  @doc """
  Records `actor`'s fave of the already-loaded `image`, which also casts an
  implicit upvote (replacing an existing downvote). Faving is idempotent.

  The image must already be loaded and authorized, with the forced-filter check
  already run. Returns `{:ok, image}` with the image
  reloaded and reindexed, or `{:error, :interaction_failed}` if the transaction
  is rolled back.

  ## Examples

      iex> create_fave(image, actor)
      {:ok, %Image{}}

  """
  @spec create_fave(Image.t(), Actor.t()) :: {:ok, Image.t()} | {:error, :interaction_failed}
  def create_fave(%Image{} = image, %Actor{user: user}) do
    ImageFaves.delete_fave_transaction(image, user)
    |> Multi.append(ImageFaves.create_fave_transaction(image, user))
    |> Multi.append(ImageVotes.delete_vote_transaction(image, user))
    |> Multi.append(ImageVotes.create_vote_transaction(image, user, true))
    |> Repo.transaction()
    |> interaction_result(image)
  end

  @doc """
  Removes `actor`'s fave of the already-loaded `image`, leaving any upvote in
  place. Unfaving is idempotent.

  Returns `{:ok, image}` with the image reloaded and reindexed, or
  `{:error, :interaction_failed}` if the transaction is rolled back.

  ## Examples

      iex> delete_fave(image, actor)
      {:ok, %Image{}}

  """
  @spec delete_fave(Image.t(), Actor.t()) :: {:ok, Image.t()} | {:error, :interaction_failed}
  def delete_fave(%Image{} = image, %Actor{user: user}) do
    image
    |> ImageFaves.delete_fave_transaction(user)
    |> Repo.transaction()
    |> interaction_result(image)
  end

  @doc """
  Records `actor`'s vote on the already-loaded `image` - an upvote when `up` is
  true, a downvote when false - replacing any existing vote. Voting is idempotent.

  The image must already be loaded and authorized, with the forced-filter check
  already run. Returns `{:ok, image}` with the image
  reloaded and reindexed, or `{:error, :interaction_failed}` if the transaction
  is rolled back.

  ## Examples

      iex> create_vote(image, actor, true)
      {:ok, %Image{}}

  """
  @spec create_vote(Image.t(), Actor.t(), boolean()) ::
          {:ok, Image.t()} | {:error, :interaction_failed}
  def create_vote(%Image{} = image, %Actor{user: user}, up) do
    ImageVotes.delete_vote_transaction(image, user)
    |> Multi.append(ImageVotes.create_vote_transaction(image, user, up))
    |> Repo.transaction()
    |> interaction_result(image)
  end

  @doc """
  Removes `actor`'s vote on the already-loaded `image`. Unvoting is idempotent.

  Returns `{:ok, image}` with the image reloaded and reindexed, or
  `{:error, :interaction_failed}` if the transaction is rolled back.

  ## Examples

      iex> delete_vote(image, actor)
      {:ok, %Image{}}

  """
  @spec delete_vote(Image.t(), Actor.t()) :: {:ok, Image.t()} | {:error, :interaction_failed}
  def delete_vote(%Image{} = image, %Actor{user: user}) do
    image
    |> ImageVotes.delete_vote_transaction(user)
    |> Repo.transaction()
    |> interaction_result(image)
  end

  defp interaction_result({:ok, _changes}, image),
    do: {:ok, get_image!(image.id) |> reindex_image()}

  defp interaction_result(_error, _image), do: {:error, :interaction_failed}

  @doc """
  Assembles the interaction listing for the image named by `image_id`, on behalf
  of `actor`.

  The image is loaded by id and authorized for `:index` (visible for any
  non-hidden image, and to staff for hidden ones). A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:index` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`.

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
    with {:ok, id} <- IntegerId.parse(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :index, image),
         %Image{} <- image do
      image = Repo.preload(image, faves: :user)

      case authorize(actor, :tamper, image) do
        :ok ->
          {:ok, {Repo.preload(image, upvotes: :user, downvotes: :user, hides: :user), true}}

        {:error, :unauthorized} ->
          {:ok, {image, false}}
      end
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Clears `actor`'s unread notifications for the image named by `image_id`.

  The image is loaded by id with no authorization: any authenticated actor may
  mark any image read, so there is deliberately no visibility check. A
  non-castable or unknown id is `{:error, :not_found}`.

  Returns `{:ok, image}` after clearing `actor`'s image comment and image merge
  notifications for it.

  ## Examples

      iex> mark_image_read(user, "42")
      {:ok, %Image{}}

      iex> mark_image_read(user, "nonexistent")
      {:error, :not_found}

  """
  @spec mark_image_read(Actor.t(), IntegerId.integer_id()) ::
          {:ok, Image.t()} | {:error, :not_found}
  def mark_image_read(%Actor{} = actor, image_id) do
    with {:ok, id} <- IntegerId.parse(image_id),
         %Image{} = image <- Repo.get(Image, id) do
      clear_image_notification(image, actor.user)
      {:ok, image}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Removes all image notifications for a given image and user.

  ## Examples

      iex> clear_image_notification(image, user)
      :ok

  """
  def clear_image_notification(%Image{} = image, user) do
    Notifications.clear_image_comment_notification(image, user)
    Notifications.clear_image_merge_notification(image, user)
    :ok
  end
end
