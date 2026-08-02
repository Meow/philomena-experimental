defmodule Philomena.Tags do
  @moduledoc """
  The Tags context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]
  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.Attribution.Actor

  alias PhilomenaQuery.Search
  alias Philomena.IndexWorker
  alias Philomena.TagAliasWorker
  alias Philomena.TagUnaliasWorker
  alias Philomena.TagReindexWorker
  alias Philomena.TagDeleteWorker
  alias Philomena.Tags.Implication
  alias Philomena.Tags.Tag
  alias Philomena.Tags.TagPage
  alias Philomena.Tags.Uploader
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Images.Search, as: ImageSearch
  alias Philomena.Images.Search.Scope
  alias Philomena.Interactions
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Users
  alias Philomena.Users.User
  alias Philomena.Filters
  alias Philomena.Filters.Filter
  alias Philomena.Images.Tagging
  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.DnpEntries.DnpEntry
  alias Philomena.Channels.Channel
  alias Philomena.TagChanges

  # There is a really delicate nuance that must be known to avoid deadlocks in
  # vectorized mutation queries such as `INSERT ON CONFLICT UPDATE`, `UPDATE`,
  # `DELETE`, `SELECT FOR [NO KEY] UPDATE` that touch multiple records. Note that
  # `INSERT ON CONFLICT DO NOTHING` doesn't lock the conflicting records, so this
  # nuance doesn't apply in that case (https://dba.stackexchange.com/questions/322912/will-insert-on-conflict-do-nothing-lock-the-row-in-case-of-conflict)
  #
  # If a vectorized mutation is run without a consistent locking order of the records,
  # it can end up with a deadlock where one transaction locks a set of records
  # that overlap with the other transaction while the other transaction locks
  # the other set that overlaps with the first transaction. Thus, both transactions
  # wait for each other to release the locks on records they locked resulting in
  # a deadlock.
  #
  # For raw `UPDATE/DELETE ... WHERE ... IN (...)` queries, the items inside `IN (...)`
  # don't influence the order of locking. These queries also don't have an `ORDER BY`
  # clause. Thus, this function returns a `SELECT [lock_type]` query that establishes a
  # consistent order of records by primary keys that must be used with all vectorized
  # mutation queries to avoid deadlocks. This query can be used as a subquery in
  # the `WHERE` clause for the vectorized mutation.
  #
  # If no locking order is set, the deadlock can appear randomly and its probability
  # increases with the amount of items in the vectorized mutation query and with
  # the number of overlapping records in concurrent transactions.
  #
  # This phenomena was discovered when @MareStare was trying to parallelize
  # the image creation process for seeding the images during development, where
  # tons of image uploads are issued in parallel with many overlapping tags
  # (https://github.com/philomena-dev/philomena/pull/481).
  #
  # Big thanks to this StackOverflow post for explanations:
  # https://stackoverflow.com/questions/27262900/postgres-update-and-lock-ordering/27263824#27263824
  defmacrop vectorized_mutation_lock(lock_type, tag_ids) do
    quote do
      Tag
      |> select([t], t.id)
      |> lock(unquote(lock_type))
      |> where([t], t.id in ^unquote(tag_ids))
      |> order_by([t], t.id)
    end
  end

  # Creates a tag. Visible for testing.
  @doc false
  def create_tag(attrs \\ %{}) do
    %Tag{}
    |> Tag.creation_changeset(attrs)
    |> Repo.insert()
  end

  # Updates a tag.
  defp update_tag(%Tag{} = tag, attrs) do
    tag_input = Tag.parse_tag_list(attrs["implied_tag_list"])

    implied_tags =
      Tag
      |> where([t], t.name in ^tag_input)
      |> Repo.all()

    tag
    |> Tag.changeset(attrs, implied_tags)
    |> Repo.update()
    |> reindex_after_update(tag)
  end

  defp reindex_after_update(result, old_tag) do
    case result do
      {:ok, tag} ->
        if tag.category != old_tag.category do
          reindex_tag_images(tag)
        end

        reindex_tag(tag)
        {:ok, tag}

      error ->
        error
    end
  end

  # Updates a tag's associated image.
  #
  # Takes a tag and image upload attributes, analyzes the upload,
  # persists it, and removes the old tag image if successful.
  defp update_tag_image(%Tag{} = tag, attrs) do
    tag
    |> Uploader.analyze_upload(attrs)
    |> Repo.update()
    |> case do
      {:ok, tag} ->
        Uploader.persist_upload(tag)
        Uploader.unpersist_old_upload(tag)

        {:ok, tag}

      error ->
        error
    end
  end

  # Removes a tag's associated image.
  defp remove_tag_image(%Tag{} = tag) do
    tag
    |> Tag.remove_image_changeset()
    |> Repo.update()
    |> case do
      {:ok, tag} ->
        Uploader.unpersist_old_upload(tag)

        {:ok, tag}

      error ->
        error
    end
  end

  # Deletes a tag.
  defp delete_tag(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", TagDeleteWorker, [tag.id])

    {:ok, tag}
  end

  # Performs the actual deletion of a tag.
  #
  # Removes the tag from the database, deletes its search index,
  # reindexes all images that were tagged with it, and cleans up
  # any empty tag changes.
  @doc false
  def perform_delete(tag_id) do
    tag = get_tag!(tag_id)

    image_ids =
      Image
      |> join(:inner, [i], _ in assoc(i, :tags))
      |> where([_i, t], t.id == ^tag.id)
      |> select([i, _t], i.id)
      |> Repo.all()

    {:ok, tag} = Repo.delete(tag)

    Search.delete_document(tag.id, Tag)

    TagChanges.delete_empty_tag_changes()

    Image
    |> where([i], i.id in ^image_ids)
    |> preload(^Images.indexing_preloads())
    |> Search.reindex(Image)
  end

  # Creates an alias from one tag to another.
  #
  # Takes a source tag and target tag name, creating an alias relationship
  # where the source tag becomes an alias of the target tag. Once the alias
  # is created, a job is queued to finish processing the alias.
  @doc false
  def alias_tag(%Tag{} = tag, attrs) do
    target_tag = Repo.get_by(Tag, name: String.downcase(attrs["target_tag"]))

    tag
    |> Repo.preload(:aliased_tag)
    |> Tag.alias_changeset(target_tag)
    |> Repo.update()
    |> case do
      {:ok, tag} ->
        Exq.enqueue(Exq, "indexing", TagAliasWorker, [tag.id, target_tag.id])

        {:ok, tag}

      error ->
        error
    end
  end

  # Performs the actual tag aliasing operation.
  #
  # Transfers all associations from the source tag to the target tag,
  # including image taggings, filters, user watches, and other relationships.
  # Updates counters and reindexes affected records.
  @doc false
  def perform_alias(tag_id, target_tag_id) do
    tag = get_tag!(tag_id)
    target_tag = get_tag!(target_tag_id)

    filters_hidden =
      where(Filter, [f], fragment("? @> ARRAY[?]::integer[]", f.hidden_tag_ids, ^tag.id))

    filters_spoilered =
      where(Filter, [f], fragment("? @> ARRAY[?]::integer[]", f.spoilered_tag_ids, ^tag.id))

    users_watching =
      where(User, [u], fragment("? @> ARRAY[?]::integer[]", u.watched_tag_ids, ^tag.id))

    array_replace(filters_hidden, :hidden_tag_ids, tag.id, target_tag.id)
    array_replace(filters_spoilered, :spoilered_tag_ids, tag.id, target_tag.id)
    array_replace(users_watching, :watched_tag_ids, tag.id, target_tag.id)

    # Create taggings with the new tag ID on images where the old tag ID is used.
    retag_query =
      from i in Image,
        inner_join: it in Tagging,
        on: it.image_id == i.id,
        select: %{image_id: i.id, tag_id: ^target_tag.id},
        where: it.tag_id == ^tag.id

    Repo.insert_all(Tagging, retag_query, on_conflict: :nothing)

    # Delete taggings on the source tag
    Tagging
    |> where(tag_id: ^tag.id)
    |> Repo.delete_all()

    # Update other associations
    ArtistLink
    |> where(tag_id: ^tag.id)
    |> Repo.update_all(set: [tag_id: target_tag.id])

    DnpEntry
    |> where(tag_id: ^tag.id)
    |> Repo.update_all(set: [tag_id: target_tag.id])

    Channel
    |> where(associated_artist_tag_id: ^tag.id)
    |> Repo.update_all(set: [associated_artist_tag_id: target_tag.id])

    # Update counter
    Tag
    |> where(id: ^tag.id)
    |> Repo.update_all(
      set: [images_count: 0, aliased_tag_id: target_tag.id, updated_at: DateTime.utc_now()]
    )

    # Finally, reindex
    reindex_tag_images(target_tag)
    reindex_tags([tag, target_tag])

    :ok
  end

  # Performs removal of a tag alias.
  #
  # Removes the alias relationship between two tags and reindexes
  # the images of the formerly aliased tag.
  @doc false
  def perform_unalias(tag_id) do
    tag = get_tag!(tag_id)
    former_alias = Repo.preload(tag, :aliased_tag).aliased_tag

    tag
    |> Tag.unalias_changeset()
    |> Repo.update()
    |> case do
      {:ok, _} = result ->
        reindex_tag_images(former_alias)
        reindex_tags([tag, former_alias])

        result

      result ->
        result
    end
  end

  defp array_replace(queryable, column, old_value, new_value) do
    queryable
    |> update(
      [q],
      set: [
        {
          ^column,
          fragment("array_replace(?, ?, ?)", field(q, ^column), ^old_value, ^new_value)
        }
      ]
    )
    |> Repo.update_all([])
  end

  # Copies tags from one image to another.
  #
  # Creates new taggings on the target image for all tags present on the source image,
  # updates tag counters, and returns the list of copied tags.
  @doc false
  def copy_tags(source, target) do
    # TODO: is this still a bug? can it work with type-casting in the select line?

    # Ecto bug:
    # ** (DBConnection.EncodeError) Postgrex expected a binary, got 5.
    #
    # what I would like to do:
    #   |> select([t], %{image_id: ^target.id, tag_id: t.tag_id})
    #
    # what I have to do instead:

    taggings =
      Tagging
      |> where(image_id: ^source.id)
      |> select([t], %{image_id: ^to_string(target.id), tag_id: t.tag_id})
      |> Repo.all()
      |> Enum.map(&%{&1 | image_id: String.to_integer(&1.image_id)})

    {:ok, tag_ids} =
      Repo.transaction(fn ->
        {_count, taggings} =
          Repo.insert_all(Tagging, taggings, on_conflict: :nothing, returning: [:tag_id])

        tag_ids = Enum.map(taggings, & &1.tag_id)

        update_image_counts(Repo, 1, tag_ids)

        tag_ids
      end)

    Tag
    |> where([t], t.id in ^tag_ids)
    |> Repo.all()
  end

  # Accepts IDs of tags and increments their `images_count` by 1.
  @doc false
  @spec update_image_counts(module(), integer(), [integer()]) :: integer()
  def update_image_counts(repo, diff, tag_ids)

  def update_image_counts(_repo, _diff, []), do: 0

  def update_image_counts(repo, diff, tag_ids) do
    locked_tags = vectorized_mutation_lock("FOR NO KEY UPDATE", tag_ids)

    {rows_affected, _} =
      Tag
      |> where([t], t.id in subquery(locked_tags))
      |> repo.update_all(inc: [images_count: diff])

    rows_affected
  end

  # Returns an `%Ecto.Changeset{}` for tracking tag changes.
  defp change_tag(%Tag{} = tag) do
    Tag.changeset(tag, %{})
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
      |> Repo.transaction()
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

  # Associations loaded when showing, editing, or updating a tag.
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

  # Associations loaded when aliasing or reindexing a tag.
  @alias_preloads [:implied_tags, :aliased_tag]

  # Associations loaded when editing a tag's spoiler image.
  @image_preloads [:implied_tags]

  @doc """
  Loads the tag named by `slug`, with its aliases, implications, and DNP
  entries preloaded.

  Lookup is strictly by slug. An unknown slug is `{:error, :not_found}`; an
  aliased tag is returned as itself, its `:aliased_tag` carrying the target.

  Returns `{:ok, tag}` or `{:error, :not_found}`.

  ## Examples

      iex> load_tag("safe")
      {:ok, %Tag{}}

      iex> load_tag("nonexistent")
      {:error, :not_found}

  """
  @spec load_tag(String.t()) :: {:ok, Tag.t()} | {:error, :not_found}
  def load_tag(slug) do
    Tag
    |> where(slug: ^slug)
    |> preload([:aliased_tag, :aliases, :implied_tags, :implied_by_tags, :dnp_entries])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      tag -> {:ok, tag}
    end
  end

  @doc """
  Searches tags with the query string `query_string` and `pagination`, sorted
  by image count descending.

  An empty or missing `query_string` compiles to a match-none query, returning
  an empty page. Returns `{:ok, tags}`, or `{:error, msg}` when `query_string`
  fails to compile.

  ## Options

    * `:preload` - associations loaded onto the results. Defaults to the
      aliases, implications, and DNP entries the tag API representation
      renders.
    * `:sort` - the search sort to apply. Defaults to image count descending.
    * `:page_size` - fixes the result window, overriding the page size
      requested in `pagination`.

  ## Examples

      iex> search_tags("artist:*", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_tags(")", pagination)
      {:error, "Imbalanced parentheses."}

  """
  @spec search_tags(String.t() | nil, map(), Keyword.t()) ::
          {:ok, Scrivener.Page.t()} | {:error, String.t()}
  def search_tags(query_string, pagination, opts \\ []) do
    preloads =
      Keyword.get(opts, :preload, [
        :aliased_tag,
        :aliases,
        :implied_tags,
        :implied_by_tags,
        :dnp_entries
      ])

    sort = Keyword.get(opts, :sort, %{images: :desc})

    pagination =
      case Keyword.fetch(opts, :page_size) do
        {:ok, page_size} -> Map.put(pagination, :page_size, page_size)
        :error -> pagination
      end

    with {:ok, query} <- Philomena.Tags.Query.compile(query_string) do
      tags =
        Tag
        |> Search.search_definition(%{query: query, sort: sort}, pagination)
        |> Search.search_records(preload(Tag, ^preloads))

      {:ok, tags}
    end
  end

  @doc """
  Assembles the `TagPage` for the viewer described by `scope`, loading the
  tag named by `slug`.

  Loads the tag with its preloads and authorizes `:show`. An unknown
  slug the viewer may act on (an admin) is `{:error, :not_found}`; otherwise it
  is `{:error, :unauthorized}`. A tag that is aliased into another is
  `{:aliased_to, tag}`, its `:aliased_tag` association carrying the target.
  Otherwise the page carries the tag, the executed page of
  images tagged with it, the viewer's interactions, and the escaped search
  query for the tag.

  Returns `{:ok, %TagPage{}}`, `{:aliased_to, tag}`, `{:error, :not_found}`,
  or `{:error, :unauthorized}`.

  ## Examples

      iex> load_tag_page(scope, "safe")
      {:ok, %TagPage{}}

      iex> load_tag_page(scope, "artist-colon-somebody")
      {:aliased_to, %Tag{}}

  """
  @spec load_tag_page(Scope.t(), String.t()) ::
          {:ok, TagPage.t()} | {:aliased_to, Tag.t()} | {:error, :not_found | :unauthorized}
  def load_tag_page(%Scope{} = scope, slug) do
    tag = tag_by_slug(slug, @show_preloads)

    with :ok <- authorize(scope.user, :show, tag),
         %Tag{} <- tag do
      case tag do
        %{aliased_tag: %Tag{}} ->
          {:aliased_to, tag}

        _tag ->
          {images, _tags} = ImageSearch.query(scope, %{term: %{"tags" => tag.name}})
          images = ImageSearch.execute(images)

          {:ok,
           %TagPage{
             tag: tag,
             images: images,
             interactions: Interactions.user_interactions(images, scope.user),
             search_query: maybe_escape_name(tag)
           }}
      end
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Loads the tag named by `slug` for editing, on behalf of `actor`.

  Authorizes `:edit`. An unknown slug the actor may act on (an admin) is
  `{:error, :not_found}`; otherwise it is `{:error, :unauthorized}`.

  The tag carries the associations named by `opts[:preload]`, defaulting to
  the full show preloads.

  Returns `{:ok, {tag, changeset}}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_tag_for_edit(moderator, "safe")
      {:ok, {%Tag{}, %Ecto.Changeset{}}}

  """
  @spec load_tag_for_edit(Actor.t(), String.t(), Keyword.t()) ::
          {:ok, {Tag.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_tag_for_edit(%Actor{} = actor, slug, opts \\ []) do
    load_tag_changeset(actor, :edit, slug, Keyword.get(opts, :preload, @show_preloads))
  end

  @doc """
  Loads the tag named by `slug` for editing its aliasing, on behalf of `actor`.

  Authorizes `:alias`. An unknown slug the actor may act on (an admin) is
  `{:error, :not_found}`; otherwise it is `{:error, :unauthorized}`.

  Returns `{:ok, {tag, changeset}}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_tag_alias_for_edit(admin, "safe")
      {:ok, {%Tag{}, %Ecto.Changeset{}}}

  """
  @spec load_tag_alias_for_edit(Actor.t(), String.t()) ::
          {:ok, {Tag.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_tag_alias_for_edit(%Actor{} = actor, slug) do
    load_tag_changeset(actor, :alias, slug, @alias_preloads)
  end

  # Authorization runs before the nil check, so an unknown slug is not-found
  # only for an actor the rule permits acting on the nil load.
  defp load_tag_changeset(actor, action, slug, preloads) do
    tag = tag_by_slug(slug, preloads)

    with :ok <- authorize(actor, action, tag),
         %Tag{} <- tag do
      {:ok, {tag, change_tag(tag)}}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Assembles the tag usage detail for the tag named by `slug`, on behalf of
  `actor`.

  Authorizes `:edit` on tags first. On success the result carries the
  tag, the filters that spoiler it, the filters that hide it, and the users
  watching it.

  Returns `{:ok, %{tag:, filters_spoilering:, filters_hiding:, users_watching:}}`,
  `{:error, :not_found}`, or `{:error, :unauthorized}`.

  ## Examples

      iex> tag_detail(moderator, "safe")
      {:ok, %{tag: %Tag{}, filters_spoilering: [], filters_hiding: [], users_watching: []}}

  """
  @spec tag_detail(Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :unauthorized}
  def tag_detail(%Actor{} = actor, slug) do
    # TODO: should make a result structure for this function
    with :ok <- authorize(actor, :edit, %Tag{}) do
      case tag_by_slug(slug, []) do
        nil ->
          {:error, :not_found}

        tag ->
          filters_spoilering =
            Filter
            |> where([f], fragment("? @> ARRAY[?]::integer[]", f.spoilered_tag_ids, ^tag.id))
            |> preload(:user)
            |> Repo.all()

          filters_hiding =
            Filter
            |> where([f], fragment("? @> ARRAY[?]::integer[]", f.hidden_tag_ids, ^tag.id))
            |> preload(:user)
            |> Repo.all()

          users_watching =
            User
            |> where([u], fragment("? @> ARRAY[?]::integer[]", u.watched_tag_ids, ^tag.id))
            |> Repo.all()

          {:ok,
           %{
             tag: tag,
             filters_spoilering: filters_spoilering,
             filters_hiding: filters_hiding,
             users_watching: users_watching
           }}
      end
    end
  end

  defp tag_by_slug(slug, preloads) do
    Tag
    |> preload(^preloads)
    |> Repo.get_by(slug: slug)
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

  # Gets a single tag.
  defp get_tag!(id), do: Repo.get!(Tag, id)

  @doc """
  Gets a single tag by its name.

  Returns nil if the Tag does not exist.

  ## Examples

      iex> get_tag_by_name("safe")
      %Tag{}

      iex> get_tag_by_name("nonexistent")
      nil

  """
  def get_tag_by_name(name), do: Repo.get_by(Tag, name: name)

  @doc """
  Gets a single tag by its name, or the tag it is aliased to, if it is aliased.

  Returns nil if the tag does not exist.

  ## Examples

      iex> get_tag_or_alias_by_name("safe")
      %Tag{}

      iex> get_tag_or_alias_by_name("nonexistent")
      nil

  """
  def get_tag_or_alias_by_name(nil), do: nil

  def get_tag_or_alias_by_name(name) do
    Tag
    |> where(name: ^name)
    |> preload(:aliased_tag)
    |> Repo.one()
    |> case do
      nil -> nil
      tag -> tag.aliased_tag || tag
    end
  end

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
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def watch_tag(%Actor{user: user}, slug) do
    case tag_by_slug(slug, []) do
      nil -> {:error, :not_found}
      tag -> Users.watch_tag(user, tag)
    end
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
          {:ok, User.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_found}
  def unwatch_tag(%Actor{user: user}, slug) do
    case tag_by_slug(slug, []) do
      nil -> {:error, :not_found}
      tag -> Users.unwatch_tag(user, tag)
    end
  end

  @doc """
  Updates the tag named by `slug` on behalf of `actor`.

  Authorizes `:edit` first. On success a moderation log is written attributing
  the update to `actor`.

  Returns `{:ok, tag}`, `{:error, %Ecto.Changeset{}}`, `{:error, :not_found}`,
  or `{:error, :unauthorized}`.

  ## Examples

      iex> update_tag(moderator, "safe", %{"category" => "rating"})
      {:ok, %Tag{}}

  """
  @spec update_tag(Actor.t(), String.t(), map()) ::
          {:ok, Tag.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def update_tag(%Actor{} = actor, slug, attrs) do
    tag = tag_by_slug(slug, @show_preloads)

    with :ok <- authorize(actor, :edit, tag),
         %Tag{} <- tag,
         {:ok, tag} <- update_tag(tag, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Tag:update",
        Paths.tag_path(tag),
        "Updated details on tag '#{tag.name}'"
      )

      {:ok, tag}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  Updates the spoiler image of the tag named by `slug`, on behalf of `actor`.

  Authorizes `:edit` first. On success a moderation log is written attributing
  the update to `actor`.

  Returns `{:ok, tag}`, `{:error, %Ecto.Changeset{}}`, `{:error, :not_found}`,
  or `{:error, :unauthorized}`.

  ## Examples

      iex> update_tag_image(moderator, "safe", %{"image" => upload})
      {:ok, %Tag{}}

  """
  @spec update_tag_image(Actor.t(), String.t(), map()) ::
          {:ok, Tag.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def update_tag_image(%Actor{} = actor, slug, attrs) do
    tag = tag_by_slug(slug, @image_preloads)

    with :ok <- authorize(actor, :edit, tag),
         %Tag{} <- tag,
         {:ok, tag} <- update_tag_image(tag, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Tag.Image:update",
        Paths.tag_path(tag),
        "Updated image on tag '#{tag.name}'"
      )

      {:ok, tag}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  Removes the spoiler image of the tag named by `slug`, on behalf of `actor`.

  Authorizes `:edit` first. On success a moderation log is written attributing
  the removal to `actor`.

  Returns `{:ok, tag}`, `{:error, %Ecto.Changeset{}}`, `{:error, :not_found}`,
  or `{:error, :unauthorized}`.

  ## Examples

      iex> remove_tag_image(moderator, "safe")
      {:ok, %Tag{}}

  """
  @spec remove_tag_image(Actor.t(), String.t()) ::
          {:ok, Tag.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def remove_tag_image(%Actor{} = actor, slug) do
    tag = tag_by_slug(slug, @image_preloads)

    with :ok <- authorize(actor, :edit, tag),
         %Tag{} <- tag,
         {:ok, tag} <- remove_tag_image(tag) do
      ModerationLogs.create_moderation_log(
        actor,
        "Tag.Image:delete",
        Paths.tag_path(tag),
        "Removed image on tag '#{tag.name}'"
      )

      {:ok, tag}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  Queues the tag named by `slug` for deletion on behalf of `actor`.

  Authorizes `:delete` first. On success a moderation log is written
  attributing the deletion to `actor`.

  Returns `{:ok, tag}`, `{:error, :not_found}`, or `{:error, :unauthorized}`.

  ## Examples

      iex> delete_tag(admin, "garbage-tag")
      {:ok, %Tag{}}

  """
  @spec delete_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()} | {:error, :not_found | :unauthorized}
  def delete_tag(%Actor{} = actor, slug) do
    tag = tag_by_slug(slug, @show_preloads)

    with :ok <- authorize(actor, :delete, tag),
         %Tag{} <- tag do
      {:ok, tag} = delete_tag(tag)

      ModerationLogs.create_moderation_log(
        actor,
        "Tag:delete",
        Paths.tag_path(tag),
        "Deleted tag '#{tag.name}'"
      )

      {:ok, tag}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Aliases the tag named by `slug` on behalf of `actor`.

  Authorizes `:alias` first. On success a moderation log is written
  attributing the alias to `actor`.

  Returns `{:ok, tag}`, `{:error, %Ecto.Changeset{}}`, `{:error, :not_found}`,
  or `{:error, :unauthorized}`.

  ## Examples

      iex> alias_tag(admin, "artist-colon-somebody", %{"target_tag" => "somebody"})
      {:ok, %Tag{}}

  """
  @spec alias_tag(Actor.t(), String.t(), map()) ::
          {:ok, Tag.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def alias_tag(%Actor{} = actor, slug, attrs) do
    tag = tag_by_slug(slug, @alias_preloads)

    with :ok <- authorize(actor, :alias, tag),
         %Tag{} <- tag,
         {:ok, tag} <- alias_tag(tag, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Tag.Alias:update",
        Paths.tag_path(tag),
        "Aliased tag '#{tag.name}' into '#{tag.aliased_tag.name}'"
      )

      {:ok, tag}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{}} = error -> error
    end
  end

  @doc """
  Enqueues reindexing of all images associated with a tag.

  ## Examples

      iex> reindex_tag_images(tag)
      {:ok, %Tag{}}

  """
  def reindex_tag_images(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", TagReindexWorker, [tag.id])

    {:ok, tag}
  end

  @doc """
  Enqueues reindexing of the tag named by `slug` and its images, on behalf of
  `actor`.

  Authorizes `:alias` first. An unknown slug the actor may act on (an admin) is
  `{:error, :not_found}`; otherwise it is `{:error, :unauthorized}`.

  Returns `{:ok, tag}`, `{:error, :not_found}`, or `{:error, :unauthorized}`.

  ## Examples

      iex> reindex_tag_by_slug(admin, "safe")
      {:ok, %Tag{}}

  """
  @spec reindex_tag_by_slug(Actor.t(), String.t()) ::
          {:ok, Tag.t()} | {:error, :not_found | :unauthorized}
  def reindex_tag_by_slug(%Actor{} = actor, slug) do
    tag = tag_by_slug(slug, @alias_preloads)

    with :ok <- authorize(actor, :alias, tag),
         %Tag{} <- tag do
      {:ok, tag} = reindex_tag_images(tag)
      reindex_tag(tag)

      {:ok, tag}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
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
    tag = get_tag!(tag_id)

    # First recount the tag
    image_count =
      Image
      |> join(:inner, [i], _ in assoc(i, :tags))
      |> where([i, t], i.hidden_from_users == false and t.id == ^tag.id)
      |> Repo.aggregate(:count, :id)

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
  Enqueues removal of a tag alias.

  ## Examples

      iex> unalias_tag(tag)
      {:ok, %Tag{}}

  """
  def unalias_tag(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", TagUnaliasWorker, [tag.id])

    {:ok, tag}
  end

  @doc """
  Queues removal of the alias on the tag named by `slug`, on behalf of `actor`.

  Authorizes `:alias` first. An unknown slug the actor may act on (an admin) is
  `{:error, :not_found}`; otherwise it is `{:error, :unauthorized}`. On success
  a moderation log is written attributing the dealias to `actor`.

  Returns `{:ok, tag}`, `{:error, :not_found}`, or `{:error, :unauthorized}`.

  ## Examples

      iex> unalias_tag(admin, "artist-colon-somebody")
      {:ok, %Tag{}}

  """
  @spec unalias_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()} | {:error, :not_found | :unauthorized}
  def unalias_tag(%Actor{} = actor, slug) do
    tag = tag_by_slug(slug, @alias_preloads)

    with :ok <- authorize(actor, :alias, tag),
         %Tag{} <- tag do
      {:ok, tag} = unalias_tag(tag)

      ModerationLogs.create_moderation_log(
        actor,
        "Tag.Alias:delete",
        Paths.tag_path(tag),
        "Dealiased tag '#{tag.name}'"
      )

      {:ok, tag}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Queues a single tag for search index updates.
  Returns the tag struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_tag(tag)
      %Tag{}

  """
  def reindex_tag(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Tags", "id", [tag.id]])

    tag
  end

  @doc """
  Queues a list of tags for search index updates.
  Returns the list of tags unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_tags([%Tag{}, %Tag{}, ...])
      [%Tag{}, %Tag{}, ...]

  """
  def reindex_tags(tags) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Tags", "id", Enum.map(tags, & &1.id)])

    tags
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
    # TODO: Couldn't this be a single delete statement that returns the ids?
    tag_ids =
      from(t in Tag,
        as: :tag,
        where: t.description == "",
        where: is_nil(t.short_description) or t.short_description == "",
        where: is_nil(t.category) or t.category == "",
        where: is_nil(t.mod_notes) or t.mod_notes == "",
        where: is_nil(t.image),
        where: is_nil(t.aliased_tag_id),
        where: not exists(where(Images.Tagging, tag_id: parent_as(:tag).id)),
        where: not exists(where(Tag, aliased_tag_id: parent_as(:tag).id)),
        where: not exists(where(Implication, tag_id: parent_as(:tag).id)),
        where: not exists(where(Implication, implied_tag_id: parent_as(:tag).id)),
        where: not exists(where(ArtistLink, tag_id: parent_as(:tag).id)),
        where: not exists(where(DnpEntry, tag_id: parent_as(:tag).id)),
        select: t.id
      )
      |> Repo.all()

    {count, _} =
      Tag
      |> where([t], t.id in ^tag_ids)
      |> Repo.delete_all()

    if count > 0 do
      PhilomenaQuery.Search.delete_documents(tag_ids, Tag)
    end

    {count, tag_ids}
  end
end
