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

  alias Philomena.ArtistLinks
  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.Attribution.Actor
  alias Philomena.Channels
  alias Philomena.DnpEntries
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
  alias Philomena.TagChanges
  alias Philomena.TagChanges.TagChange
  alias Philomena.TagChanges.TagChangeTag
  alias Philomena.Tags.Implication
  alias Philomena.Tags.QueryBuilder
  alias Philomena.Tags.QueryForm
  alias Philomena.Tags.QuickTagTable
  alias Philomena.Tags.Tag
  alias Philomena.Tags.TagDetail
  alias Philomena.Tags.TagPage
  alias Philomena.Tags.TagSuggestion
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

  # Creates a tag. Visible for testing.
  @doc false
  def create_tag(attrs \\ %{}) do
    %Tag{}
    |> Tag.creation_changeset(attrs)
    |> Repo.insert()
  end

  defp locked_tag_ids(tag_ids) do
    Tag
    |> where([tag], tag.id in ^tag_ids)
    |> order_by([tag], tag.id)
    |> select([tag], tag.id)
    |> lock("FOR NO KEY UPDATE")
  end

  defp load_tag_for_action(actor, action, slug, preloads) when is_binary(slug) do
    Tag
    |> where(slug: ^slug)
    |> preload(^preloads)
    |> Loader.one_and_authorize(actor, action)
  end

  defp load_tag_for_action(_actor, _action, _slug, _preloads), do: {:error, :not_found}

  defp reindex_tag_images(%Tag{} = tag) do
    Exq.enqueue(Exq, "indexing", TagReindexWorker, [tag.id])
    tag
  end

  defp reindex_tag_ids([]), do: []

  defp reindex_tag_ids(tag_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Tags", "id", tag_ids])
    tag_ids
  end

  # Computes the search query that lists the tag's images. A tag whose name
  # compiles back to itself is used verbatim. Anything else is escaped so the
  # search parser does not reinterpret it.
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

  defp filtered_taggings_for_batch(batch_query, [{:hidden_from_users, hidden_from_users}]) do
    from tagging in batch_query,
      as: :tagging,
      where:
        tagging.image_id in subquery(
          from image in Image,
            where: image.id == parent_as(:tagging).image_id,
            where: image.hidden_from_users == ^hidden_from_users,
            select: image.id
        )
  end

  defp insert_all_for_alias(filtered_batch_query, target_tag) do
    select(
      filtered_batch_query,
      [tagging],
      %{image_id: tagging.image_id, tag_id: type(^target_tag.id, :integer)}
    )
  end

  @doc """
  Gets existing tags or creates new ones from a tag list string.

  Takes a string of comma-separated tag names, parses it into individual tags,
  and either retrieves existing tags or creates new ones for tags that don't exist.
  Resolves tag aliases to the target tag.

  ## Examples

      iex> get_or_create_tags("safe, cute, pony")
      [%Tag{name: "safe"}, %Tag{name: "cute"}, %Tag{name: "pony"}]

  """
  @spec get_or_create_tags(String.t()) :: [Tag.t()]
  def get_or_create_tags(tag_list) do
    with tag_names when tag_names != [] <- Tag.parse_tag_list(tag_list) do
      tag_query =
        Tag
        |> where([tag], tag.name in ^tag_names)
        |> preload([:implied_tags, aliased_tag: :implied_tags])

      insert_rows =
        Enum.map(tag_names, fn tag_name ->
          %Tag{}
          |> Tag.creation_changeset(%{name: tag_name})
          |> Ecto.Changeset.apply_changes()
          |> Map.take(Tag.insert_fields())
          |> Map.merge(%{
            created_at: {:placeholder, :timestamp},
            updated_at: {:placeholder, :timestamp}
          })
        end)

      insert_options = [
        placeholders: %{timestamp: DateTime.utc_now(:second)},
        on_conflict: :nothing,
        returning: [:id]
      ]

      {:ok, %{all_tags: all_tags}} =
        Multi.new()
        |> Multi.insert_all(:new_tags, Tag, insert_rows, insert_options)
        |> Multi.all(:all_tags, tag_query)
        |> Multi.on_commit(fn %{new_tags: {_count, new_tags}} -> reindex_tags(new_tags) end)
        |> Multi.transact()

      all_tags
      |> Enum.map(&(&1.aliased_tag || &1))
      |> Enum.uniq_by(& &1.id)
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
    with {:ok, tag} <- load_tag_for_action(actor, :show, slug, [:aliased_tag]),
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
  Loads the tags matching the supplied integer IDs.

  Unknown IDs are omitted and results are not guaranteed to follow input
  order. Request parsing and request-specific limits remain the caller's
  responsibility.

  ## Examples

      iex> list_tags_by_ids([42, 999_999_999])
      [%Tag{id: 42}]

  """
  @spec list_tags_by_ids([integer()]) :: [Tag.t()]
  def list_tags_by_ids(ids) when is_list(ids) do
    Tag
    |> where([tag], tag.id in ^ids)
    |> Repo.all()
  end

  @doc """
  Returns tag suggestions for a normalized search-as-you-type term.

  Canonical names and aliases are prefix-matched in OpenSearch. PostgreSQL is
  authoritative for image counts, so results are filtered and re-sorted after
  loading to tolerate temporary index desynchronization. At most ten indexed
  candidates are considered.

  ## Examples

      iex> autocomplete_tags("pon", 2)
      [%TagSuggestion{alias: nil, canonical: "pony", images: 42}]

  """
  @spec autocomplete_tags(String.t(), 1..10) :: [TagSuggestion.t()]
  def autocomplete_tags(term, limit \\ 10)

  def autocomplete_tags(term, limit)
      when is_binary(term) and is_integer(limit) and limit > 0 and limit <= 10 do
    Tag
    |> Search.search_definition(
      %{
        query: %{
          bool: %{
            should: [
              %{prefix: %{name: term}},
              %{prefix: %{name_in_namespace: term}}
            ]
          }
        },
        sort: %{images: :desc}
      },
      %{page_size: 10}
    )
    |> Search.search_records(preload(Tag, :aliased_tag))
    |> Enum.map(fn tag ->
      canonical = tag.aliased_tag || tag

      %TagSuggestion{
        alias: if(tag.aliased_tag, do: tag.name),
        canonical: canonical.name,
        images: canonical.images_count
      }
    end)
    |> Enum.filter(&(&1.images > 0))
    |> Enum.sort_by(& &1.images, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Returns the cached data used to render the quick-tag table.

  The cache is stored in `:persistent_term` because the table is read on many
  requests and changes only when explicitly refreshed or the VM restarts.

  ## Examples

      iex> table = quick_tag_table()
      iex> is_map(table.tags) and is_map(table.shipping)
      true

  """
  @spec quick_tag_table() :: QuickTagTable.t()
  def quick_tag_table, do: QuickTagTable.get()

  @doc """
  Recomputes and replaces the cached quick-tag table data.

  ## Examples

      iex> table = refresh_quick_tag_table()
      iex> is_map(table.data)
      true

  """
  @spec refresh_quick_tag_table() :: QuickTagTable.t()
  def refresh_quick_tag_table, do: QuickTagTable.refresh()

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
      tag_input =
        tag
        |> Tag.changeset(attrs)
        |> Ecto.Changeset.get_field(:implied_tag_list)
        |> Tag.parse_tag_list()

      implied_tags =
        Tag
        |> where([t], t.name in ^tag_input)
        |> Repo.all()

      Multi.new()
      |> Multi.update(:tag, Tag.changeset(tag, attrs, implied_tags))
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag:update",
        Paths.tag_path(tag),
        "Updated details on tag '#{tag.name}'"
      )
      |> Multi.on_commit(fn %{tag: updated_tag} ->
        # credo:disable-for-next-line
        if updated_tag.category != tag.category do
          reindex_tag_images(updated_tag)
        end

        reindex_tags([updated_tag])
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
      tag_image_changeset = Uploader.analyze_upload(tag, attrs)

      Multi.new()
      |> Multi.update(:tag, tag_image_changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag.Image:update",
        Paths.tag_path(tag),
        "Updated image on tag '#{tag.name}'"
      )
      |> Multi.on_commit(fn %{tag: tag} ->
        Uploader.persist_upload(tag)
        Uploader.unpersist_old_upload(tag)
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
      |> Multi.update(:tag, Tag.remove_image_changeset(tag))
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag.Image:delete",
        Paths.tag_path(tag),
        "Removed image on tag '#{tag.name}'"
      )
      |> Multi.on_commit(fn %{tag: tag} -> Uploader.unpersist_old_upload(tag) end)
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
  Queues the tag named by `slug` for deletion on behalf of `actor`.

  Write access and `:delete` authorization precede an atomic audit insert. The
  destruction worker is released only after that audit commits.

  ## Examples

      iex> delete_tag(admin, "garbage-tag")
      {:ok, %Tag{}}

  """
  @spec delete_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def delete_tag(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :delete, slug, @show_preloads),
         {:ok, _tag} <-
           tag
           |> Tag.deletion_changeset()
           |> Ecto.Changeset.apply_action(:update) do
      Multi.new()
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag:delete",
        Paths.tag_path(tag),
        "Deleted tag '#{tag.name}'"
      )
      |> Multi.on_commit(fn _changes ->
        Exq.enqueue(Exq, "indexing", TagDeleteWorker, [tag.id])
      end)
      |> Multi.transact()
      |> case do
        {:ok, _changes} ->
          {:ok, tag}
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
      Multi.new()
      |> Multi.update(:tag, alias_changeset)
      |> Filters.put_replace_tag_references(
        :update_hidden_filters,
        :update_spoilered_filters,
        tag.id,
        target_tag.id
      )
      |> Users.put_replace_watched_tag(:update_users_watching, tag.id, target_tag.id)
      |> ArtistLinks.put_alias_tag(tag.id, target_tag.id)
      |> DnpEntries.put_replace_tag(:update_dnp_entries, tag.id, target_tag.id)
      |> Channels.put_replace_artist_tag(:update_channels, tag.id, target_tag.id)
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
      reindex_tag_images(tag)
      reindex_tags([tag])

      {:ok, tag}
    end
  end

  @doc """
  Removes the alias on the tag named by `slug`, on behalf of `actor`.

  Write access, `:unalias` authorization, the relationship update, and the
  audit log share one transaction. Image and tag reindexing runs after commit.

  ## Examples

      iex> unalias_tag(admin, "artist-colon-somebody")
      {:ok, %Tag{}}

  """
  @spec unalias_tag(Actor.t(), String.t()) ::
          {:ok, Tag.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def unalias_tag(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, tag} <- load_tag_for_action(actor, :unalias, slug, @alias_preloads) do
      unalias_changeset = Tag.unalias_changeset(tag)
      former_alias = tag.aliased_tag

      Multi.new()
      |> Multi.update(:tag, unalias_changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Tag.Alias:delete",
        Paths.tag_path(tag),
        "Dealiased tag '#{tag.name}'"
      )
      |> Multi.on_commit(fn %{tag: tag} ->
        reindex_tag_images(former_alias)
        reindex_tags([tag, former_alias])
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
  Adds a tag image-count adjustment to `multi`.

  The callback form allows reading tag IDs from prior Multi changes.
  """
  @spec put_image_count_delta(
          Multi.t(),
          Multi.name(),
          (Multi.changes() -> [integer()]),
          integer()
        ) :: Multi.t()
  def put_image_count_delta(%Multi{} = multi, step, tag_ids_callback, diff) do
    Multi.run(multi, step, fn repo, changes ->
      {:ok, update_image_counts(repo, diff, tag_ids_callback.(changes))}
    end)
    |> Multi.on_commit(fn changes ->
      reindex_tag_ids(tag_ids_callback.(changes))
    end)
  end

  @doc """
  Upserts image-count deltas for bulk image tag changes inside `multi`.

  Images supplies inserted and deleted tagging steps. Tags owns the tag-table
  upsert and queues every affected tag for indexing after commit.
  """
  @spec put_batch_image_count_changes(Multi.t(), Multi.name(), Multi.name()) :: Multi.t()
  def put_batch_image_count_changes(%Multi{} = multi, inserted_step, deleted_step) do
    multi
    |> Multi.run(:batch_tag_counts, fn repo, changes ->
      inserted =
        changes
        |> Map.fetch!(inserted_step)
        |> elem(1)
        |> Enum.map(&[&1.image_id, &1.tag_id])

      deleted = changes |> Map.fetch!(deleted_step) |> elem(1)
      now = DateTime.utc_now(:second)

      # In order to merge into the existing tables here in one go, insert_all
      # is used with a query that is guaranteed to conflict on every row by
      # using the primary key. This will update the image counts via the
      # ON CONFLICT DO UPDATE clause.
      rows =
        (tag_upsert_data(inserted, now, true) ++ tag_upsert_data(deleted, now, false))
        |> Enum.group_by(& &1.id)
        |> Enum.map(fn {_id, [first | rest]} ->
          Enum.reduce(rest, first, fn row, acc ->
            %{acc | images_count: acc.images_count + row.images_count}
          end)
        end)

      {_, _} =
        repo.insert_all(Tag, rows,
          on_conflict: update(Tag, inc: [images_count: fragment("EXCLUDED.images_count")]),
          conflict_target: [:id]
        )

      {:ok, Enum.uniq(Enum.map(rows, & &1.id))}
    end)
    |> Multi.on_commit(fn %{batch_tag_counts: tag_ids} -> reindex_tag_ids(tag_ids) end)
  end

  # Generate data for inserts/updates of the Tags.Tag struct.
  defp tag_upsert_data(changes, now, added) do
    changes
    |> Enum.group_by(fn [_image_id, tag_id] -> tag_id end)
    |> Enum.map(fn {tag_id, instances} ->
      %{
        id: tag_id,
        name: "",
        slug: "",
        created_at: now,
        updated_at: now,
        images_count: if(added, do: length(instances), else: -length(instances))
      }
    end)
  end

  @doc """
  Adds tag copying from `source` to `target` to an image merge transaction.

  Only newly inserted target taggings increment tag image counters.

  ## Examples

      iex> put_copy_tags(multi, source_image, target_image)
      %Philomena.Multi{}

  """
  @spec put_copy_tags(Multi.t(), Image.t(), Image.t()) :: Multi.t()
  def put_copy_tags(%Multi{} = multi, %Image{} = source, %Image{} = target) do
    multi
    |> Images.put_copy_taggings(source, target)
    |> put_image_count_delta(
      :update_image_counts,
      fn %{copied_tag_ids: copied_tag_ids} -> copied_tag_ids end,
      1
    )
  end

  @doc """
  Worker entry point that deletes a queued tag and repairs dependent indexes.

  Taggings are deleted in batches to avoid holding locks for the full migration.

  ## Examples

      iex> perform_delete(42)
      :ok

  """
  @spec perform_delete(integer()) :: :ok
  def perform_delete(tag_id) do
    tag = Repo.get!(Tag, tag_id)

    # Clean up image taggings

    Tagging
    |> where(tag_id: ^tag.id)
    |> Batch.query_batches(batch_size: 1_000, id_field: :image_id)
    |> Enum.each(fn batch_query ->
      # Lock all images in the batch first to prevent image operations from racing tag updates.
      image_query =
        from image in Image,
          where: image.id in subquery(select(batch_query, [tagging], tagging.image_id)),
          order_by: [asc: :id],
          select: image.id

      # The image counter represents only the count of visible images.
      # To preserve this meaning, the operation must be split into deleting
      # taggings of visible and non-visible images.
      #
      # The image counter is updated so the partial deletion state is resumable.

      visible_taggings = filtered_taggings_for_batch(batch_query, hidden_from_users: false)
      hidden_taggings = filtered_taggings_for_batch(batch_query, hidden_from_users: true)

      Multi.new()
      |> Multi.lock_all(:image_ids, image_query)
      |> Images.put_delete_taggings(:old_visible, visible_taggings)
      |> Images.put_delete_taggings(:old_hidden, hidden_taggings)
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

    # Clean up tag changes

    TagChangeTag
    |> where(tag_id: ^tag.id)
    |> Batch.query_batches(batch_size: 10_000, id_field: :tag_change_id)
    |> Enum.each(fn batch_query ->
      tag_change_query =
        from tag_change in TagChange,
          where: tag_change.id in subquery(select(batch_query, [t], t.tag_change_id)),
          order_by: [asc: :id],
          select: tag_change.id

      Multi.new()
      |> Multi.lock_all(:tag_change_ids, tag_change_query)
      |> TagChanges.put_delete_tag_change_tags(:tag_change_tags, batch_query)
      |> Multi.transact()
    end)

    # Deletion now proceeds

    Multi.new()
    |> Multi.delete(:tag, tag)
    |> Multi.on_commit(fn _changes -> Search.delete_document(tag.id, Tag) end)
    |> Multi.transact()

    TagChanges.cleanup_empty_for_tag_deletion()

    :ok
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
    |> Batch.query_batches(batch_size: 1_000, id_field: :image_id)
    |> Enum.each(fn batch_query ->
      # Lock all images in the batch first to prevent image operations from racing tag updates.
      image_query =
        from image in Image,
          where: image.id in subquery(select(batch_query, [tagging], tagging.image_id)),
          order_by: [asc: :id]

      # The image counter represents only the count of visible images.
      # To preserve this meaning, the operation must be split into migrating
      # taggings of visible and non-visible images.
      #
      # The image counter is updated so the partial migration state is resumable.

      visible_taggings = filtered_taggings_for_batch(batch_query, hidden_from_users: false)
      visible_insert_all = insert_all_for_alias(visible_taggings, target_tag)

      hidden_taggings = filtered_taggings_for_batch(batch_query, hidden_from_users: true)
      hidden_insert_all = insert_all_for_alias(hidden_taggings, target_tag)

      Multi.new()
      |> Multi.lock_all(:images, image_query)
      |> Images.put_insert_taggings(:new_visible, visible_insert_all)
      |> Images.put_insert_taggings(:new_hidden, hidden_insert_all)
      |> Images.put_delete_taggings(:old_visible, visible_taggings)
      |> Images.put_delete_taggings(:old_hidden, hidden_taggings)
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
      |> Multi.on_commit(fn _changes ->
        reindex_tag_images(target_tag)
        reindex_tags([tag, target_tag])
      end)
      |> Multi.transact()
    end)

    :ok
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
    Multi.new()
    |> Multi.run(:image_count, fn repo, _changes ->
      {:ok,
       Image
       |> join(:inner, [i], _ in assoc(i, :tags))
       |> where([i, t], i.hidden_from_users == false and t.id == ^tag.id)
       |> repo.aggregate(:count)}
    end)
    |> Multi.update_all(
      :update_tag,
      fn %{image_count: image_count} ->
        Tag
        |> where(id: ^tag.id)
        |> update(set: [images_count: ^image_count])
      end,
      []
    )
    |> Multi.on_commit(fn _changes -> reindex_tags([tag]) end)
    |> Multi.transact()

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

  @doc """
  Queues a list of tags for search index updates.
  Returns the list of tags unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_tags([%Tag{}, %Tag{}, ...])
      [%Tag{}, %Tag{}, ...]

  """
  @spec reindex_tags([Tag.t()]) :: [Tag.t()]
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
end
