defmodule Philomena.Tags do
  @moduledoc """
  Tag discovery, metadata moderation, aliasing, and indexing services.

  Controller-facing APIs resolve a real slug before authorization and name
  whether aliases remain distinct or resolve to their canonical target. Bulk
  counter, alias, deletion, and reindex operations are explicit composition or
  worker services.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.Attribution.Actor
  alias Philomena.Channels.Channel
  alias Philomena.DnpEntries.DnpEntry
  alias Philomena.Filters
  alias Philomena.Filters.Filter
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Images.Tagging
  alias Philomena.IndexWorker
  alias Philomena.Interactions
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Multi
  alias Philomena.Repo
  alias Philomena.TagAliasWorker
  alias Philomena.TagDeleteWorker
  alias Philomena.TagReindexWorker
  alias Philomena.TagUnaliasWorker
  alias Philomena.TagChanges
  alias Philomena.Tags.Implication
  alias Philomena.Tags.QueryBuilder
  alias Philomena.Tags.QueryForm
  alias Philomena.Tags.Tag
  alias Philomena.Tags.TagDetail
  alias Philomena.Tags.TagPage
  alias Philomena.Tags.Uploader
  alias Philomena.Users
  alias Philomena.Users.User
  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search

  @show_preloads [
    :aliases,
    :aliased_tag,
    :implied_tags,
    :implied_by_tags,
    :dnp_entries,
    :channels,
    public_links: :user,
    hidden_links: :user
  ]

  @api_preloads [:aliased_tag, :aliases, :implied_tags, :implied_by_tags, :dnp_entries]
  @alias_preloads [:implied_tags, :aliased_tag]
  @image_preloads [:implied_tags]

  defp locked_tag_ids(tag_ids) do
    Tag
    |> where([tag], tag.id in ^tag_ids)
    |> order_by([tag], tag.id)
    |> select([tag], tag.id)
    |> lock("FOR NO KEY UPDATE")
  end

  defp tag_by_slug(slug, preloads) when is_binary(slug) do
    Tag
    |> where(slug: ^slug)
    |> preload(^preloads)
    |> Loader.one()
  end

  defp tag_by_slug(_slug, _preloads), do: {:error, :not_found}

  defp load_tag_for_action(actor, action, slug, preloads) do
    with {:ok, tag} <- tag_by_slug(slug, preloads),
         :ok <- authorize(actor, action, tag) do
      {:ok, tag}
    end
  end

  # Creates a tag. Visible for testing.
  @doc false
  def create_tag(attrs \\ %{}) do
    %Tag{}
    |> Tag.creation_changeset(attrs)
    |> Repo.insert()
  end

  defp tag_changeset(%Tag{} = tag, attrs) do
    tag_input =
      tag
      |> Tag.changeset(attrs)
      |> Ecto.Changeset.get_field(:implied_tag_list)
      |> Tag.parse_tag_list()

    implied_tags =
      Tag
      |> where([t], t.name in ^tag_input)
      |> Repo.all()

    Tag.changeset(tag, attrs, implied_tags)
  end

  defp reindex_updated_tag(tag, old_tag) do
    if tag.category != old_tag.category do
      enqueue_image_reindex(tag)
    end

    enqueue_tag_reindex(tag)
  end

  defp tag_image_changeset(%Tag{} = tag, attrs), do: Uploader.analyze_upload(tag, attrs)

  defp remove_tag_image_changeset(%Tag{} = tag), do: Tag.remove_image_changeset(tag)

  defp enqueue_delete(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", TagDeleteWorker, [tag.id])
    tag
  end

  defp enqueue_unalias(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", TagUnaliasWorker, [tag.id])
    tag
  end

  defp enqueue_image_reindex(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", TagReindexWorker, [tag.id])
    tag
  end

  defp enqueue_tag_reindex(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Tags", "id", [tag.id]])
    tag
  end

  defp enqueue_tag_reindex(tags) when is_list(tags) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Tags", "id", Enum.map(tags, & &1.id)])
    tags
  end

  defp enqueue_tag_id_reindex(tag_ids) when is_list(tag_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Tags", "id", tag_ids])
    tag_ids
  end

  defp prepare_array_replace(queryable, column, old_value, new_value) do
    update(queryable, [q],
      set: [
        {^column, fragment("array_replace(?, ?, ?)", field(q, ^column), ^old_value, ^new_value)}
      ]
    )
  end

  # Computes the search query that lists the tag's images. A tag whose name
  # compiles back to itself is used verbatim; anything else is escaped so the
  # search parser does not reinterpret it.
  defp maybe_escape_name(%{name: name}) do
    name =
      name
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.downcase()

    case Images.Query.compile(name) do
      {:ok, %{term: %{"tags" => ^name}}} ->
        name

      _error ->
        escape_name(name)
    end
  end

  defp escape_name(name) do
    if String.contains?(name, "(") or String.contains?(name, ")") do
      # \ * ? " should be escaped, wrap in quotes so parser doesn't
      # choke on parens.
      name =
        name
        |> String.replace("\\", "\\\\")
        |> String.replace("*", "\\*")
        |> String.replace("?", "\\?")
        |> String.replace("\"", "\\\"")

      "\"#{name}\""
    else
      # \ * ? - ! " all must be escaped.
      name
      |> String.replace(~r/\A-/, "\\-")
      |> String.replace(~r/\A!/, "\\!")
      |> String.replace("\\", "\\\\")
      |> String.replace("*", "\\*")
      |> String.replace("?", "\\?")
      |> String.replace("\"", "\\\"")
    end
  end

  @spec get_or_create_non_empty_tags_list(list(String.t())) :: list()
  defp get_or_create_non_empty_tags_list(tag_names) do
    tags =
      tag_names
      |> Enum.map(fn tag_name ->
        %Tag{}
        |> Tag.creation_changeset(%{name: tag_name})
        |> Ecto.Changeset.apply_changes()
        |> Map.take([
          :slug,
          :name,
          :category,
          :images_count,
          :description,
          :short_description,
          :namespace,
          :name_in_namespace,
          :image,
          :image_format,
          :image_mime_type,
          :mod_notes
        ])
        |> Map.merge(%{
          created_at: {:placeholder, :timestamp},
          updated_at: {:placeholder, :timestamp}
        })
      end)

    %{new_tags: {_rows_affected, new_tags}, all_tags: all_tags} =
      Multi.new()
      |> Multi.insert_all(
        :new_tags,
        Tag,
        tags,
        placeholders: %{timestamp: DateTime.utc_now(:second)},
        on_conflict: :nothing,
        returning: [:id]
      )
      |> Multi.all(
        :all_tags,
        Tag
        |> where([t], t.name in ^tag_names)
        |> preload([:implied_tags, aliased_tag: :implied_tags])
      )
      |> Multi.transact()
      |> case do
        {:ok, ok} ->
          ok

        result ->
          raise "get_or_create_tags failed: #{inspect(result)}\ntag_names: #{inspect(tag_names)}"
      end

    new_tags
    |> reindex_tags()

    all_tags
    |> Enum.map(&(&1.aliased_tag || &1))
    |> Enum.uniq_by(& &1.id)
  end

  defp filtered_taggings_for_alias(batch_query, target_tag, [
         {:hidden_from_users, hidden_from_users}
       ]) do
    taggings =
      from tagging in batch_query,
        as: :tagging,
        where:
          tagging.image_id in subquery(
            from image in Image,
              where: image.id == parent_as(:tagging).image_id,
              where: image.hidden_from_users == ^hidden_from_users,
              select: image.id
          )

    insert_all =
      select(
        taggings,
        [tagging],
        %{image_id: tagging.image_id, tag_id: type(^target_tag.id, :integer)}
      )

    {taggings, insert_all}
  end

  @doc """
  Worker entry point that deletes a queued tag and repairs dependent indexes.

  The tag row and its database cascades commit before OpenSearch cleanup,
  empty TagChanges cleanup, and affected-image reindexing run.

  ## Examples

      iex> perform_delete(42)
      :ok

  """
  @spec perform_delete(integer()) :: :ok
  def perform_delete(tag_id) do
    tag = Repo.get!(Tag, tag_id)

    image_ids_query =
      Image
      |> join(:inner, [image], _tag in assoc(image, :tags))
      |> where([_image, joined_tag], joined_tag.id == ^tag.id)
      |> select([image, _joined_tag], image.id)

    Multi.new()
    |> Multi.all(:image_ids, image_ids_query)
    |> Multi.delete(:tag, tag)
    |> Multi.on_commit(fn %{image_ids: image_ids, tag: tag} ->
      Search.delete_document(tag.id, Tag)
      TagChanges.cleanup_empty_for_tag_deletion()

      Image
      |> where([image], image.id in ^image_ids)
      |> preload(^Images.indexing_preloads())
      |> Search.reindex(Image)
    end)
    |> Multi.transact()
    |> case do
      {:ok, _changes} -> :ok
      {:error, step, reason, _changes} -> raise "tag delete failed at #{step}: #{inspect(reason)}"
    end
  end

  @doc """
  Worker entry point that migrates an alias's taggings to its target.

  Taggings are moved in batches to avoid holding locks for the full migration.

  ## Examples

      iex> perform_alias(12, 13)
      :ok

  """
  @spec perform_alias(integer(), integer()) :: :ok
  def perform_alias(tag_id, target_tag_id) do
    tag = Repo.get!(Tag, tag_id)
    target_tag = Repo.get!(Tag, target_tag_id)

    Tagging
    |> where(tag_id: ^tag.id)
    |> Batch.query_batches(batch_size: 10_000, id_field: :image_id)
    |> Enum.each(fn batch_query ->
      # Lock all images in the batch first to prevent image operations from racing tag updates.
      image_query =
        from image in Image,
          where: image.id in subquery(select(batch_query, [tagging], tagging.image_id)),
          order_by: [asc: :id]

      # The image counter represents only the count of visible images.
      # To preserve this meaning, the operation must be split into migrating
      # taggings of visible and non-visible images.

      {visible_taggings, visible_insert_all} =
        filtered_taggings_for_alias(batch_query, target_tag, hidden_from_users: false)

      {hidden_taggings, hidden_insert_all} =
        filtered_taggings_for_alias(batch_query, target_tag, hidden_from_users: true)

      Multi.new()
      |> Multi.lock_all(:images, image_query)
      |> Multi.insert_all(:new_visible, Tagging, visible_insert_all, on_conflict: :nothing)
      |> Multi.insert_all(:new_hidden, Tagging, hidden_insert_all, on_conflict: :nothing)
      |> Multi.delete_all(:old_visible, visible_taggings)
      |> Multi.delete_all(:old_hidden, hidden_taggings)
      |> Multi.update_all(
        :target_tag,
        fn %{new_visible: {count, _}} ->
          Tag
          |> where(id: ^target_tag.id)
          |> update(inc: [images_count: ^count])
        end,
        []
      )
      |> Multi.update_all(
        :source_tag,
        fn %{old_visible: {count, _}} ->
          Tag
          |> where(id: ^tag.id)
          |> update(inc: [images_count: ^(-count)])
        end,
        []
      )
      |> Multi.transact()
    end)

    enqueue_image_reindex(target_tag)
    enqueue_tag_reindex([tag, target_tag])

    :ok
  end

  @doc """
  Worker entry point that removes a queued alias and repairs its indexes.

  ## Examples

      iex> perform_unalias(12)
      {:ok, %Tag{}}

  """
  @spec perform_unalias(integer()) :: {:ok, Tag.t()} | {:error, Ecto.Changeset.t()}
  def perform_unalias(tag_id) do
    tag = Repo.get!(Tag, tag_id)
    former_alias = Repo.preload(tag, :aliased_tag).aliased_tag

    Multi.new()
    |> Multi.update(:tag, Tag.unalias_changeset(tag))
    |> Multi.on_commit(fn %{tag: tag} ->
      enqueue_image_reindex(former_alias)
      enqueue_tag_reindex([tag, former_alias])
    end)
    |> Multi.transact()
    |> case do
      {:ok, %{tag: tag}} -> {:ok, tag}
      {:error, :tag, changeset, _changes} -> {:error, changeset}
    end
  end

  @doc """
  Adds tag copying from `source` to `target` to an image-merge transaction.

  Only newly inserted target taggings increment tag image counters.

  ## Examples

      iex> put_copy_tags(multi, source_image, target_image)
      %Philomena.Multi{}

  """
  @spec put_copy_tags(Multi.t(), Image.t(), Image.t()) :: Multi.t()
  def put_copy_tags(%Multi{} = multi, %Image{} = source, %Image{} = target) do
    source_taggings_query =
      Tagging
      |> where(image_id: ^source.id)
      |> select([tagging], %{
        image_id: type(^target.id, :integer),
        tag_id: tagging.tag_id
      })

    multi
    |> Multi.all(:source_taggings, source_taggings_query)
    |> Multi.insert_all(
      :target_taggings,
      Tagging,
      fn %{source_taggings: source_taggings} ->
        source_taggings
      end,
      on_conflict: :nothing,
      returning: [:tag_id]
    )
    |> Multi.run(:copied_tag_ids, fn _repo, %{target_taggings: {_count, target_taggings}} ->
      {:ok, Enum.map(target_taggings, & &1.tag_id)}
    end)
    |> Multi.run(:update_image_counts, fn repo, %{copied_tag_ids: copied_tag_ids} ->
      {:ok, update_image_counts(repo, 1, copied_tag_ids)}
    end)
    |> Multi.on_commit(fn %{copied_tag_ids: copied_tag_ids} ->
      enqueue_tag_id_reindex(copied_tag_ids)
    end)
  end

  @doc """
  Applies `diff` to each tag's image count inside the caller's transaction.

  Overlapping bulk updates must lock tag rows in ascending primary-key order.
  PostgreSQL otherwise may acquire the update locks in different orders and
  deadlock concurrent image writes; this invariant was reproduced by parallel
  uploads in philomena-dev/philomena#483.

  ## Examples

      iex> update_image_counts(repo, 1, [12, 13])
      2

  """
  @spec update_image_counts(module(), integer(), [integer()]) :: integer()
  def update_image_counts(repo, diff, tag_ids)

  def update_image_counts(_repo, _diff, []), do: 0

  def update_image_counts(repo, diff, tag_ids) do
    locked_tags = locked_tag_ids(tag_ids)

    {rows_affected, _} =
      Tag
      |> where([t], t.id in subquery(locked_tags))
      |> repo.update_all(inc: [images_count: diff])

    rows_affected
  end

  @doc """
  Gets existing tags or creates new ones from a tag list string.

  Takes a string of comma-separated tag names, parses it into individual tags,
  and either retrieves existing tags or creates new ones for tags that don't exist.
  Also handles tag aliases by returning the aliased tag instead of the alias.

  ## Examples

      iex> get_or_create_tags("safe, cute, pony")
      [%Tag{name: "safe"}, %Tag{name: "cute"}, %Tag{name: "pony"}]

  """
  @spec get_or_create_tags(String.t()) :: list()
  def get_or_create_tags(tag_list) do
    case Tag.parse_tag_list(tag_list) do
      [] -> []
      tag_names -> get_or_create_non_empty_tags_list(tag_names)
    end
  end

  @doc """
  Loads the visible tag named by `slug` without resolving aliases.

  The JSON representation uses this API so an alias remains independently
  addressable. Missing and malformed slugs are not found before `:show`
  authorization.

  ## Examples

      iex> load_tag(actor, "safe")
      {:ok, %Tag{}}

      iex> load_tag(actor, "nonexistent")
      {:error, :not_found}

  """
  @spec load_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()} | {:error, :not_found | :unauthorized}
  def load_tag(%Actor{} = actor, slug) do
    load_tag_for_action(actor, :show, slug, @api_preloads)
  end

  @doc """
  Loads the visible canonical tag named by `slug`.

  Aliases resolve to their target before `:show` authorization. TagChanges uses
  this boundary for history links. Missing and malformed slugs are not found.

  ## Examples

      iex> load_canonical_tag(actor, "safe")
      {:ok, %Tag{}}

      iex> load_canonical_tag(actor, "missing")
      {:error, :not_found}

  """
  @spec load_canonical_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()} | {:error, :not_found | :unauthorized}
  def load_canonical_tag(%Actor{} = actor, slug) do
    with {:ok, tag} <- tag_by_slug(slug, :aliased_tag),
         tag = tag.aliased_tag || tag,
         :ok <- authorize(actor, :show, tag) do
      {:ok, tag}
    end
  end

  @doc """
  Searches the tag index on behalf of `actor`.

  `params["query"]` owns the query language input. Invalid syntax returns its
  rejected query-form changeset; missing input intentionally compiles to the
  established match-none query. Results sort by image count, name, then ID and
  carry the associations needed by the public tag representation.

  ## Examples

      iex> search_tags(actor, %{"query" => "artist:*"}, pagination)
      {:ok, %Scrivener.Page{}, %Ecto.Changeset{}}

      iex> search_tags(actor, %{"query" => ")"}, pagination)
      {:error, %Ecto.Changeset{}}

  """
  @spec search_tags(Actor.t(), map(), Search.pagination_params()) ::
          {:ok, Scrivener.Page.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | Ecto.Changeset.t()}
  def search_tags(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, Tag),
         {:ok, body, query_form} <- QueryBuilder.build_query(params) do
      tags =
        Tag
        |> Search.search_definition(body, pagination)
        |> Search.search_records(preload(Tag, ^@api_preloads))

      {:ok, tags, QueryForm.changeset(query_form)}
    end
  end

  @doc """
  Assembles the `TagPage` for the viewer described by `scope`, loading the
  tag named by `slug`.

  Loads the tag before `:show` authorization. Missing and malformed slugs are
  always not found. A tag that is aliased into another is
  `{:aliased_to, tag}`, its `:aliased_tag` association carrying the target.
  Otherwise the page carries the tag, the executed page of
  images tagged with it, the viewer's interactions, and the escaped search
  query for the tag.

  Returns `{:ok, %TagPage{}}`, `{:aliased_to, tag}`, `{:error, :not_found}`,
  or `{:error, :unauthorized}`.

  ## Examples

      iex> load_tag_page(actor, scope, "safe")
      {:ok, %TagPage{}}

      iex> load_tag_page(actor, scope, "artist-colon-somebody")
      {:aliased_to, %Tag{}}

  """
  @spec load_tag_page(Actor.t(), Scope.t(), String.t()) ::
          {:ok, TagPage.t()} | {:aliased_to, Tag.t()} | {:error, :not_found | :unauthorized}
  def load_tag_page(%Actor{} = actor, %Scope{} = scope, slug) do
    with {:ok, tag} <- load_tag_for_action(actor, :show, slug, @show_preloads) do
      case tag do
        %{aliased_tag: %Tag{}} ->
          {:aliased_to, tag}

        _tag ->
          {images, _tags} = ImageSearch.query(actor, scope, %{term: %{"tags" => tag.name}})
          images = ImageSearch.execute(images)

          {:ok,
           %TagPage{
             tag: tag,
             images: images,
             interactions: Interactions.user_interactions(actor, images),
             search_query: maybe_escape_name(tag)
           }}
      end
    end
  end

  @doc """
  Loads the tag named by `slug` for editing, on behalf of `actor`.

  Write access and `:edit` authorization match the update action. Missing and
  malformed slugs are always not found.

  Returns `{:ok, {tag, changeset}}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_tag_for_edit(moderator, "safe")
      {:ok, {%Tag{}, %Ecto.Changeset{}}}

  """
  @spec load_tag_for_edit(Actor.t(), String.t()) ::
          {:ok, {Tag.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def load_tag_for_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :edit, slug, @show_preloads) do
      {:ok, {tag, Tag.changeset(tag)}}
    end
  end

  @doc """
  Loads the tag spoiler-image form on behalf of `actor`.

  Write access and `:edit_image` authorization match both image mutations.

  ## Examples

      iex> load_tag_image_for_edit(moderator, "safe")
      {:ok, {%Tag{}, %Ecto.Changeset{}}}

  """
  @spec load_tag_image_for_edit(Actor.t(), String.t()) ::
          {:ok, {Tag.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def load_tag_image_for_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :edit_image, slug, @image_preloads) do
      {:ok, {tag, Tag.changeset(tag)}}
    end
  end

  @doc """
  Loads the tag named by `slug` for editing its aliasing, on behalf of `actor`.

  Write access and `:edit_alias` authorization match alias mutations. Missing
  and malformed slugs are always not found.

  Returns `{:ok, {tag, changeset}}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_tag_alias_for_edit(admin, "safe")
      {:ok, {%Tag{}, %Ecto.Changeset{}}}

  """
  @spec load_tag_alias_for_edit(Actor.t(), String.t()) ::
          {:ok, {Tag.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def load_tag_alias_for_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :edit_alias, slug, @alias_preloads) do
      {:ok, {tag, Tag.alias_form_changeset(tag)}}
    end
  end

  @doc """
  Assembles the tag usage detail for the tag named by `slug`, on behalf of
  `actor`.

  Authorizes `:show_details` on the loaded tag. On success the result carries the
  tag, the filters that spoiler it, the filters that hide it, and the users
  watching it.

  ## Examples

      iex> tag_detail(moderator, "safe")
      {:ok, %TagDetail{tag: %Tag{}}}

  """
  @spec tag_detail(Actor.t(), String.t()) ::
          {:ok, TagDetail.t()} | {:error, :not_found | :unauthorized}
  def tag_detail(%Actor{} = actor, slug) do
    with {:ok, tag} <- load_tag_for_action(actor, :show_details, slug, []) do
      filters_spoilering =
        Filter
        |> where(
          [filter],
          fragment("? @> ARRAY[?]::integer[]", filter.spoilered_tag_ids, ^tag.id)
        )
        |> preload(:user)
        |> Repo.all()

      filters_hiding =
        Filter
        |> where([filter], fragment("? @> ARRAY[?]::integer[]", filter.hidden_tag_ids, ^tag.id))
        |> preload(:user)
        |> Repo.all()

      users_watching =
        User
        |> where([user], fragment("? @> ARRAY[?]::integer[]", user.watched_tag_ids, ^tag.id))
        |> Repo.all()

      {:ok,
       %TagDetail{
         tag: tag,
         filters_spoilering: filters_spoilering,
         filters_hiding: filters_hiding,
         users_watching: users_watching
       }}
    end
  end

  @doc """
  Finds the canonical tag named by `name`, resolving one stored alias.

  This is a trusted composition lookup for changesets in other contexts; it
  returns `nil` when the submitted name cannot identify a tag.

  ## Examples

      iex> find_canonical_tag_by_name("safe")
      %Tag{}

      iex> find_canonical_tag_by_name("nonexistent")
      nil

  """
  @spec find_canonical_tag_by_name(String.t() | nil) :: Tag.t() | nil
  def find_canonical_tag_by_name(name) when is_binary(name) do
    Tag
    |> where(name: ^Tag.clean_tag_name(name))
    |> preload(:aliased_tag)
    |> Repo.one()
    |> case do
      nil -> nil
      tag -> tag.aliased_tag || tag
    end
  end

  def find_canonical_tag_by_name(_name), do: nil

  @doc """
  Adds the tag named by `slug` to `actor`'s watched tags.

  An unknown slug is `{:error, :not_found}`. Otherwise this defers to the
  watched-tags update, which reindexes the user.

  Returns `{:ok, user}`, `{:error, %Ecto.Changeset{}}`, or
  `{:error, :not_found}`.

  ## Examples

      iex> watch_tag(actor, "safe")
      {:ok, %User{}}

  """
  @spec watch_tag(Actor.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def watch_tag(%Actor{} = actor, slug) do
    with {:ok, tag} <- load_canonical_tag(actor, slug), do: Users.watch_tag(actor, tag)
  end

  @doc """
  Removes the tag named by `slug` from `actor`'s watched tags.

  An unknown slug is `{:error, :not_found}`. Otherwise this defers to the
  watched-tags update, which reindexes the user.

  Returns `{:ok, user}`, `{:error, %Ecto.Changeset{}}`, or
  `{:error, :not_found}`.

  ## Examples

      iex> unwatch_tag(actor, "safe")
      {:ok, %User{}}

  """
  @spec unwatch_tag(Actor.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def unwatch_tag(%Actor{} = actor, slug) do
    with {:ok, tag} <- load_canonical_tag(actor, slug), do: Users.unwatch_tag(actor, tag)
  end

  @doc """
  Updates the tag named by `slug` on behalf of `actor`.

  Write access, `:update` authorization, the tag update, and its audit log share
  one workflow. Search and affected-image reindexing run only after commit.

  ## Examples

      iex> update_tag(moderator, "safe", %{"category" => "rating"})
      {:ok, %Tag{}}

  """
  @spec update_tag(Actor.t(), String.t(), map()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def update_tag(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :update, slug, @show_preloads) do
      Multi.new()
      |> Multi.update(:tag, tag_changeset(tag, attrs))
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{tag: tag} ->
        {"Tag:update", Paths.tag_path(tag), "Updated details on tag '#{tag.name}'"}
      end)
      |> Multi.on_commit(fn %{tag: updated_tag} -> reindex_updated_tag(updated_tag, tag) end)
      |> Multi.transact()
      |> case do
        {:ok, %{tag: tag}} -> {:ok, tag}
        {:error, :tag, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  @doc """
  Updates the spoiler image of the tag named by `slug`, on behalf of `actor`.

  Write access, `:update_image` authorization, the database update, and its
  audit log share one transaction. Object persistence occurs after commit.

  ## Examples

      iex> update_tag_image(moderator, "safe", %{"image" => upload})
      {:ok, %Tag{}}

  """
  @spec update_tag_image(Actor.t(), String.t(), map()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def update_tag_image(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :update_image, slug, @image_preloads) do
      Multi.new()
      |> Multi.update(:tag, tag_image_changeset(tag, attrs))
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{tag: tag} ->
        {"Tag.Image:update", Paths.tag_path(tag), "Updated image on tag '#{tag.name}'"}
      end)
      |> Multi.on_commit(fn %{tag: tag} ->
        Uploader.persist_upload(tag)
        Uploader.unpersist_old_upload(tag)
      end)
      |> Multi.transact()
      |> case do
        {:ok, %{tag: tag}} -> {:ok, tag}
        {:error, :tag, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  @doc """
  Removes the spoiler image of the tag named by `slug`, on behalf of `actor`.

  Write access, `:delete_image` authorization, the database update, and its
  audit log share one transaction. Object deletion occurs after commit.

  ## Examples

      iex> remove_tag_image(moderator, "safe")
      {:ok, %Tag{}}

  """
  @spec remove_tag_image(Actor.t(), String.t()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def remove_tag_image(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :delete_image, slug, @image_preloads) do
      Multi.new()
      |> Multi.update(:tag, remove_tag_image_changeset(tag))
      |> ModerationLogs.put_log(:moderation_log, actor, fn %{tag: tag} ->
        {"Tag.Image:delete", Paths.tag_path(tag), "Removed image on tag '#{tag.name}'"}
      end)
      |> Multi.on_commit(fn %{tag: tag} -> Uploader.unpersist_old_upload(tag) end)
      |> Multi.transact()
      |> case do
        {:ok, %{tag: tag}} -> {:ok, tag}
        {:error, :tag, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  @doc """
  Queues the tag named by `slug` for deletion on behalf of `actor`.

  Write access and `:delete` authorization precede an atomic audit insert. The
  destructive worker is released only after that audit commits.

  ## Examples

      iex> delete_tag(admin, "garbage-tag")
      {:ok, %Tag{}}

  """
  @spec delete_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def delete_tag(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :delete, slug, @show_preloads) do
      Multi.new()
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag:delete",
        Paths.tag_path(tag),
        "Deleted tag '#{tag.name}'"
      )
      |> Multi.on_commit(fn _changes -> enqueue_delete(tag) end)
      |> Multi.transact()
      |> case do
        {:ok, _changes} -> {:ok, tag}
        {:error, :moderation_log, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  @doc """
  Aliases the tag named by `slug` on behalf of `actor`.

  Write access, `:alias` authorization, the association migration, and its
  audit log share one transaction. Tagging migration and alias finalization
  are queued after commit.

  ## Examples

      iex> alias_tag(admin, "artist-colon-somebody", %{"target_tag" => "somebody"})
      {:ok, %Tag{}}

  """
  @spec alias_tag(Actor.t(), String.t(), map()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def alias_tag(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :alias, slug, @alias_preloads),
         {:ok, tag} =
           tag
           |> Tag.alias_form_changeset(attrs)
           |> Ecto.Changeset.apply_action(:update),
         target_tag = find_canonical_tag_by_name(tag.target_tag),
         alias_changeset = Tag.alias_changeset(tag, target_tag),
         {:ok, _tag} <- Ecto.Changeset.apply_action(alias_changeset, :update) do
      hidden_filters_query =
        Filter
        |> where([f], fragment("? @> ARRAY[?]::integer[]", f.hidden_tag_ids, ^tag.id))
        |> prepare_array_replace(:hidden_tag_ids, tag.id, target_tag.id)

      spoilered_filters_query =
        Filter
        |> where([f], fragment("? @> ARRAY[?]::integer[]", f.spoilered_tag_ids, ^tag.id))
        |> prepare_array_replace(:spoilered_tag_ids, tag.id, target_tag.id)

      users_watching_query =
        User
        |> where([u], fragment("? @> ARRAY[?]::integer[]", u.watched_tag_ids, ^tag.id))
        |> prepare_array_replace(:watched_tag_ids, tag.id, target_tag.id)

      artist_links_query =
        ArtistLink
        |> where(tag_id: ^tag.id)
        |> update(set: [tag_id: ^target_tag.id])

      conflicting_artist_links_query =
        from source in ArtistLink,
          join: target in ArtistLink,
          on:
            target.tag_id == ^target_tag.id and
              target.uri == source.uri and
              target.user_id == source.user_id,
          where:
            source.tag_id == ^tag.id and
              source.aasm_state != "rejected" and
              target.aasm_state != "rejected",
          select: source.id

      conflicting_artist_links_delete_query =
        from artist_link in ArtistLink,
          where: artist_link.id in subquery(conflicting_artist_links_query)

      dnp_entries_query =
        DnpEntry
        |> where(tag_id: ^tag.id)
        |> update(set: [tag_id: ^target_tag.id])

      channels_query =
        Channel
        |> where(associated_artist_tag_id: ^tag.id)
        |> update(set: [associated_artist_tag_id: ^target_tag.id])

      Multi.new()
      |> Multi.update(:tag, alias_changeset)
      |> Multi.update_all(:update_hidden_filters, hidden_filters_query, [])
      |> Multi.update_all(:update_spoilered_filters, spoilered_filters_query, [])
      |> Multi.update_all(:update_users_watching, users_watching_query, [])
      |> Multi.delete_all(
        :delete_conflicting_artist_links,
        conflicting_artist_links_delete_query
      )
      |> Multi.update_all(:update_artist_links, artist_links_query, [])
      |> Multi.update_all(:update_dnp_entries, dnp_entries_query, [])
      |> Multi.update_all(:update_channels, channels_query, [])
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag.Alias:update",
        Paths.tag_path(tag),
        "Aliased tag '#{tag.name}' into '#{target_tag.name}'"
      )
      |> Multi.on_commit(fn _changes ->
        Exq.enqueue(Exq, "indexing", TagAliasWorker, [tag.id, target_tag.id])
      end)
      |> Multi.transact()
      |> case do
        {:ok, %{tag: %Tag{} = tag}} ->
          {:ok, tag}

        {:error, :tag, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Enqueues reindexing of the tag named by `slug` and its images, on behalf of
  `actor`.

  Write access and `:reindex` authorization precede both jobs. Missing and
  malformed slugs are always not found.

  ## Examples

      iex> reindex_tag_by_slug(admin, "safe")
      {:ok, %Tag{}}

  """
  @spec reindex_tag_by_slug(Actor.t(), String.t()) ::
          {:ok, Tag.t()} | {:error, :ban | :not_found | :unauthorized}
  def reindex_tag_by_slug(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :reindex, slug, @alias_preloads) do
      enqueue_image_reindex(tag)
      enqueue_tag_reindex(tag)

      {:ok, tag}
    end
  end

  @doc """
  Performs reindexing of all images associated with a tag.

  Updates the tag's image count to reflect the current number of non-hidden images,
  then reindexes all associated images and filters that reference this tag.

  ## Examples

      iex> perform_reindex_images(123)

  """
  def perform_reindex_images(tag_id) do
    tag = Repo.get!(Tag, tag_id)

    # First recount the tag
    image_count =
      Image
      |> join(:inner, [i], _ in assoc(i, :tags))
      |> where([i, t], i.hidden_from_users == false and t.id == ^tag.id)
      |> Repo.aggregate(:count)

    Tag
    |> where(id: ^tag.id)
    |> Repo.update_all(set: [images_count: image_count])

    # Then reindex
    Image
    |> join(:inner, [i], _ in assoc(i, :tags))
    |> where([_i, t], t.id == ^tag.id)
    |> preload(^Images.indexing_preloads())
    |> Search.reindex(Image)

    Filter
    |> where([f], fragment("? @> ARRAY[?]::integer[]", f.hidden_tag_ids, ^tag.id))
    |> or_where([f], fragment("? @> ARRAY[?]::integer[]", f.spoilered_tag_ids, ^tag.id))
    |> preload(^Filters.indexing_preloads())
    |> Search.reindex(Filter)
  end

  @doc """
  Queues removal of the alias on the tag named by `slug`, on behalf of `actor`.

  Write access and `:unalias` authorization precede an atomic audit insert. The
  worker is released only after the audit commits.

  ## Examples

      iex> unalias_tag(admin, "artist-colon-somebody")
      {:ok, %Tag{}}

  """
  @spec unalias_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def unalias_tag(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :unalias, slug, @alias_preloads),
         %Ecto.Changeset{valid?: true} <- Tag.unalias_request_changeset(tag) do
      Multi.new()
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag.Alias:delete",
        Paths.tag_path(tag),
        "Dealiased tag '#{tag.name}'"
      )
      |> Multi.on_commit(fn _changes -> enqueue_unalias(tag) end)
      |> Multi.transact()
      |> case do
        {:ok, _changes} -> {:ok, tag}
        {:error, :moderation_log, changeset, _changes} -> {:error, changeset}
      end
    else
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      error -> error
    end
  end

  @doc """
  Queues a list of tags for search index updates.
  Returns the list of tags unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_tags([%Tag{}, %Tag{}, ...])
      [%Tag{}, %Tag{}, ...]

  """
  @spec reindex_tags([Tag.t()]) :: [Tag.t()]
  def reindex_tags(tags) do
    enqueue_tag_reindex(tags)
  end

  @doc """
  Returns the list of associations to preload for tag indexing.

  ## Examples

      iex> indexing_preloads()
      [:aliased_tag, :aliases, :implied_tags, :implied_by_tags]

  """
  def indexing_preloads do
    [:aliased_tag, :aliases, :implied_tags, :implied_by_tags]
  end

  @doc """
  Performs reindexing of tags based on a column condition.

  Takes a column name and a list of values to match against that column,
  then reindexes all matching tags.

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      {:ok, []}

      iex> perform_reindex(:name, ["safe", "suggestive"])
      {:ok, []}

  """
  def perform_reindex(column, condition) do
    Tag
    |> preload(^indexing_preloads())
    |> where([t], field(t, ^column) in ^condition)
    |> Search.reindex(Tag)
  end

  @doc """
  Deletes all tags that meet all of the following conditions:
  - Not present on any images
  - No description
  - No short description
  - No category
  - No mod notes
  - No spoiler image set
  - Not aliased to another tag
  - Has no aliases pointing to it
  - Does not imply any other tags
  - Is not implied by any other tags
  - Has no artist links
  - Has no DNP entries

  Also removes the deleted tags from the search index.

  ## Examples

      iex> cleanup!()
      {3, [1, 2, 3]}

  """
  def cleanup! do
    cleanup_query =
      from(tag in Tag,
        as: :tag,
        where: tag.description == "",
        where: is_nil(tag.short_description) or tag.short_description == "",
        where: is_nil(tag.category) or tag.category == "",
        where: is_nil(tag.mod_notes) or tag.mod_notes == "",
        where: is_nil(tag.image),
        where: is_nil(tag.aliased_tag_id),
        where: not exists(where(Images.Tagging, tag_id: parent_as(:tag).id)),
        where: not exists(where(Tag, aliased_tag_id: parent_as(:tag).id)),
        where: not exists(where(Implication, tag_id: parent_as(:tag).id)),
        where: not exists(where(Implication, implied_tag_id: parent_as(:tag).id)),
        where: not exists(where(ArtistLink, tag_id: parent_as(:tag).id)),
        where: not exists(where(DnpEntry, tag_id: parent_as(:tag).id)),
        select: tag.id
      )

    {count, tag_ids} = Repo.delete_all(cleanup_query)

    if count > 0 do
      PhilomenaQuery.Search.delete_documents(tag_ids, Tag)
    end

    {count, tag_ids}
  end
end
