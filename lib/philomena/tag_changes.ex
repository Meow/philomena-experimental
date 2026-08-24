defmodule Philomena.TagChanges do
  @moduledoc """
  Searchable image-tag edit history and its moderation workflows.

  Controller-facing reads resolve image, tag, user, IP, and fingerprint targets
  independently before searching. Tag-change creation composes into the owning
  Images transaction, while reindexing and batch reversion remain explicitly
  named worker services.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Attribution.Actor
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.IndexWorker
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Multi
  alias Philomena.Repo
  alias Philomena.Slug
  alias Philomena.TagChangeRevertWorker
  alias Philomena.TagChanges
  alias Philomena.TagChanges.QueryBuilder
  alias Philomena.TagChanges.QueryForm
  alias Philomena.TagChanges.RevertForm
  alias Philomena.TagChanges.SearchIndex
  alias Philomena.TagChanges.TagChange
  alias Philomena.TagChanges.TagChangePage
  alias Philomena.Tags
  alias Philomena.Tags.Tag
  alias Philomena.UserFingerprints
  alias Philomena.Users
  alias Philomena.Users.User
  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search

  @history_preloads [:user, image: [:user, :sources, tags: :aliases], tags: [:tag]]

  defp tags_to_tag_change(_tag_change, nil, _added), do: []

  defp tags_to_tag_change(tag_change, tags, added) do
    Enum.map(tags, &%{tag_change_id: tag_change.id, tag_id: &1.id, added: added})
  end

  defp cast_ip(ip) do
    case EctoNetwork.INET.cast(ip) do
      {:ok, ip} ->
        {:ok, ip}

      _error ->
        {:error, :not_found}
    end
  end

  defp cast_fingerprint(fingerprint) when is_binary(fingerprint) do
    fingerprint =
      fingerprint
      |> String.trim()
      |> String.downcase()

    if UserFingerprints.valid_format?(fingerprint) do
      {:ok, fingerprint}
    else
      {:error, :not_found}
    end
  end

  defp cast_fingerprint(_fingerprint), do: {:error, :not_found}

  defp image_visibility_filters(actor) do
    case authorize(actor, :show, %Image{hidden_from_users: true}) do
      :ok -> []
      {:error, :unauthorized} -> [%{term: %{image_hidden: false}}]
    end
  end

  defp identity_metadata?(actor), do: authorize(actor, :show, :identity_metadata) == :ok

  defp search_tag_changes(actor, resource_type, target, resource_filter, params, pagination) do
    query_options = [user: actor.user, identity_metadata?: identity_metadata?(actor)]

    with {:ok, body, query_form} <- QueryBuilder.build_query(params, query_options) do
      filters = image_visibility_filters(actor) ++ List.wrap(resource_filter)
      body = %{body | query: %{bool: %{must: [body.query | filters]}}}

      tag_changes =
        TagChange
        |> Search.search_definition(body, pagination)
        |> Search.search_records(preload(TagChange, ^@history_preloads))

      page = %TagChangePage{
        resource_type: resource_type,
        target: target,
        tag_changes: tag_changes
      }

      {:ok, page, QueryForm.changeset(query_form)}
    end
  end

  defp revert_ids(ids, attributes) do
    tag_change_query =
      from tag_change in TagChange,
        inner_join: image in assoc(tag_change, :image),
        where: tag_change.id in ^ids and image.hidden_from_users == false,
        order_by: [desc: tag_change.created_at, desc: tag_change.id],
        preload: [tags: [:tag, :tag_change]]

    tag_changes = Repo.all(tag_change_query)

    tag_changes
    |> Enum.flat_map(& &1.tags)
    |> revert_tags(attributes)
    |> case do
      {:ok, _result} -> {:ok, tag_changes}
      error -> error
    end
  end

  defp revert_tags(tags, attributes) do
    tags
    |> Enum.group_by(& &1.tag_change.image_id)
    |> Enum.map(fn {image_id, instances} ->
      changed_tags =
        instances
        |> Enum.sort_by(&{DateTime.to_unix(&1.tag_change.created_at), &1.tag_change_id})
        |> Enum.uniq_by(& &1.tag_id)

      {added_tags, removed_tags} = Enum.split_with(changed_tags, & &1.added)

      %{
        image_id: image_id,
        added_tags: Enum.map(removed_tags, & &1.tag),
        removed_tags: Enum.map(added_tags, & &1.tag)
      }
    end)
    |> Images.batch_update(attributes)
  end

  defp put_enqueue_full_revert(%Multi{} = multi, actor, target) do
    attributes = %{
      ip: to_string(actor.ip),
      fingerprint: actor.fingerprint,
      user_id: actor.user.id,
      batch_size: 100
    }

    Multi.on_commit(multi, fn _changes ->
      Exq.enqueue(Exq, "indexing", TagChangeRevertWorker, [
        Map.put(target, :attributes, attributes)
      ])
    end)
  end

  @doc """
  Enqueues a reversion of all tag changes attributed to a user profile.

  Missing profiles return `{:error, :not_found}`.
  """
  @spec full_revert_user_tag_changes(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def full_revert_user_tag_changes(%Actor{} = actor, slug) do
    with :ok <- authorize(actor, :revert, TagChange),
         {:ok, user} <- Users.load_profile(actor, slug) do
      Multi.new()
      |> put_enqueue_full_revert(actor, %{user_id: user.id})
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "TagChange.FullRevert:create",
        Paths.profile_path(user),
        "Reverted all tag changes for user #{user.name}"
      )
      |> Multi.transact()
      |> case do
        {:ok, _changes} ->
          {:ok, user}

        error ->
          error
      end
    end
  end

  @doc """
  Enqueues a reversion of all tag changes attributed to an IP address.

  Invalid IP addresses return `{:error, :not_found}`.
  """
  @spec full_revert_ip_tag_changes(Actor.t(), term()) ::
          {:ok, String.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def full_revert_ip_tag_changes(%Actor{} = actor, ip) do
    with :ok <- authorize(actor, :revert, TagChange),
         {:ok, ip} <- cast_ip(ip) do
      ip = to_string(ip)

      Multi.new()
      |> put_enqueue_full_revert(actor, %{ip: ip})
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "TagChange.FullRevert:create",
        Paths.ip_profile_path(ip),
        "Reverted all tag changes for ip #{ip}"
      )
      |> Multi.transact()
      |> case do
        {:ok, _changes} ->
          {:ok, ip}

        error ->
          error
      end
    end
  end

  @doc """
  Enqueues a reversion of all tag changes attributed to a fingerprint.

  Invalid fingerprints return `{:error, :not_found}`.
  """
  @spec full_revert_fingerprint_tag_changes(Actor.t(), term()) ::
          {:ok, String.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def full_revert_fingerprint_tag_changes(%Actor{} = actor, fingerprint) do
    with :ok <- authorize(actor, :revert, TagChange),
         {:ok, fingerprint} <- cast_fingerprint(fingerprint) do
      Multi.new()
      |> put_enqueue_full_revert(actor, %{fingerprint: fingerprint})
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "TagChange.FullRevert:create",
        Paths.fingerprint_profile_path(fingerprint),
        "Reverted all tag changes for fingerprint #{fingerprint}"
      )
      |> Multi.transact()
      |> case do
        {:ok, _changes} ->
          {:ok, fingerprint}

        error ->
          error
      end
    end
  end

  @doc """
  Searches all tag changes visible to `actor`.

  Hidden-image changes are excluded unless the actor may show their images.
  `params` accepts `tcq`, `sf`, and `sd`; invalid search or sort input returns
  a rejected query changeset. The successful result includes the normalized
  query changeset.

  ## Examples

      iex> list_tag_changes(actor, %{"tcq" => "safe"}, page: 1, page_size: 25)
      {:ok, %TagChangePage{resource_type: :all}, changeset}

  """
  @spec list_tag_changes(Actor.t(), map(), Search.pagination_params()) ::
          {:ok, TagChangePage.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | Ecto.Changeset.t()}
  def list_tag_changes(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, TagChange) do
      search_tag_changes(actor, :all, nil, [], params, pagination)
    end
  end

  @doc """
  Searches tag changes on the image named by `image_id`.

  Images owns target loading and visibility authorization. Malformed and absent
  IDs are not found; a real hidden image forbidden to the actor is unauthorized.

  ## Examples

      iex> image_tag_changes(actor, "42", %{}, page: 1, page_size: 25)
      {:ok, %TagChangePage{resource_type: :image}, changeset}

      iex> image_tag_changes(actor, "missing", %{}, page: 1, page_size: 25)
      {:error, :not_found}

  """
  @spec image_tag_changes(
          Actor.t(),
          IntegerId.integer_id(),
          map(),
          Search.pagination_params()
        ) ::
          {:ok, TagChangePage.t(), Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def image_tag_changes(%Actor{} = actor, image_id, params, pagination) do
    with {:ok, image} <- Images.load_visible_image(actor, image_id) do
      search_tag_changes(actor, :image, image, %{term: %{image_id: image.id}}, params, pagination)
    end
  end

  @doc """
  Searches tag changes involving the tag named by `tag_name`.

  The name is normalized to the tag's route slug and resolved through Tags.
  Missing tags are not found before OpenSearch is queried.

  ## Examples

      iex> tag_tag_changes(actor, "safe", %{}, page: 1, page_size: 25)
      {:ok, %TagChangePage{resource_type: :tag}, changeset}

  """
  @spec tag_tag_changes(Actor.t(), String.t(), map(), Search.pagination_params()) ::
          {:ok, TagChangePage.t(), Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def tag_tag_changes(%Actor{} = actor, tag_name, params, pagination) when is_binary(tag_name) do
    slug =
      tag_name
      |> String.downcase()
      |> Slug.slug()

    with {:ok, tag} <- Tags.load_visible_tag(actor, slug) do
      search_tag_changes(actor, :tag, tag, %{term: %{tag_id: tag.id}}, params, pagination)
    end
  end

  def tag_tag_changes(%Actor{}, _tag_name, _params, _pagination), do: {:error, :not_found}

  @doc """
  Searches tag changes attributed to the active user named by `name`.

  Users owns target loading. Ordinary viewers receive only publicly attributed
  changes; actors with identity-metadata access receive the user's true
  attribution, including changes hidden by anonymous upload attribution.

  ## Examples

      iex> user_tag_changes(actor, "Somebody", %{}, page: 1, page_size: 25)
      {:ok, %TagChangePage{resource_type: :user}, changeset}

  """
  @spec user_tag_changes(Actor.t(), String.t(), map(), Search.pagination_params()) ::
          {:ok, TagChangePage.t(), Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def user_tag_changes(%Actor{} = actor, name, params, pagination) do
    with {:ok, user} <- Users.load_profile_by_name(actor, name) do
      user_resource_filter =
        if identity_metadata?(actor) do
          %{term: %{true_user_id: user.id}}
        else
          %{term: %{user_id: user.id}}
        end

      search_tag_changes(
        actor,
        :user,
        user,
        user_resource_filter,
        params,
        pagination
      )
    end
  end

  @doc """
  Searches tag changes attributed to the canonical IP address `ip`.

  Malformed addresses are not found before the shared identity-metadata gate;
  valid addresses with no changes return an empty page.

  ## Examples

      iex> ip_tag_changes(moderator, "203.0.113.5", %{}, page: 1, page_size: 25)
      {:ok, %TagChangePage{resource_type: :ip}, changeset}

      iex> ip_tag_changes(moderator, "not-an-ip", %{}, page: 1, page_size: 25)
      {:error, :not_found}

  """
  @spec ip_tag_changes(Actor.t(), String.t(), map(), Search.pagination_params()) ::
          {:ok, TagChangePage.t(), Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def ip_tag_changes(%Actor{} = actor, ip, params, pagination) do
    with {:ok, ip} <- cast_ip(ip),
         :ok <- authorize(actor, :show, :identity_metadata) do
      search_tag_changes(actor, :ip, ip, %{term: %{ip: to_string(ip)}}, params, pagination)
    end
  end

  @doc """
  Searches tag changes attributed to a canonical browser `fingerprint`.

  The value is normalized and validated through UserFingerprints before the
  shared identity-metadata gate. Valid fingerprints with no changes return an
  empty page.

  ## Examples

      iex> fingerprint_tag_changes(moderator, "C123", %{}, page: 1, page_size: 25)
      {:ok, %TagChangePage{resource_type: :fingerprint}, changeset}

  """
  @spec fingerprint_tag_changes(Actor.t(), String.t(), map(), Search.pagination_params()) ::
          {:ok, TagChangePage.t(), Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def fingerprint_tag_changes(%Actor{} = actor, fingerprint, params, pagination) do
    with {:ok, fingerprint} <- cast_fingerprint(fingerprint),
         :ok <- authorize(actor, :show, :identity_metadata) do
      search_tag_changes(
        actor,
        :fingerprint,
        fingerprint,
        %{term: %{fingerprint: fingerprint}},
        params,
        pagination
      )
    end
  end

  @doc """
  Adds tag-change creation to an Images update transaction.

  `image_step` must return `{image, added_tags, removed_tags}`. This helper adds
  `:tag_change` and `:tag_changes` steps; the latter preserves the existing
  `{added_count, removed_count}` result. An update with no changed tags records
  no history. Search indexing is deferred until the owning transaction commits.

  ## Examples

      iex> put_tag_change(multi, actor)
      %Philomena.Multi{}

  """
  @spec put_tag_change(Multi.t(), Actor.t(), Multi.name()) :: Multi.t()
  def put_tag_change(%Multi{} = multi, %Actor{} = actor, image_step \\ :image) do
    user_id = if actor.user, do: actor.user.id

    multi
    |> Multi.run(:tag_change, fn repo, changes ->
      case Map.fetch!(changes, image_step) do
        {_image, [], []} ->
          {:ok, nil}

        {image, _added_tags, _removed_tags} ->
          repo.insert(%TagChange{
            image_id: image.id,
            user_id: user_id,
            ip: actor.ip,
            fingerprint: actor.fingerprint
          })
      end
    end)
    |> Multi.run(:tag_changes, fn repo, changes ->
      case {Map.fetch!(changes, :tag_change), Map.fetch!(changes, image_step)} do
        {nil, _image_result} ->
          {:ok, {0, 0}}

        {tag_change, {_image, added_tags, removed_tags}} ->
          {added_count, nil} =
            repo.insert_all(TagChanges.Tag, tags_to_tag_change(tag_change, added_tags, true))

          {removed_count, nil} =
            repo.insert_all(TagChanges.Tag, tags_to_tag_change(tag_change, removed_tags, false))

          {:ok, {added_count, removed_count}}
      end
    end)
    |> Multi.on_commit(fn
      %{tag_change: %TagChange{} = tag_change} ->
        Exq.enqueue(Exq, "indexing", IndexWorker, ["TagChanges", "id", [tag_change.id]])

      %{tag_change: nil} ->
        nil
    end)
  end

  @doc """
  Reverts the valid tag-change IDs in `ids` on behalf of `actor`.

  Malformed ID lists return `{:error, changeset}`. Missing IDs and changes on
  hidden images are skipped, making stale or repeated batch submissions safe.
  The successful moderation log records the number of loaded changes reverted.

  ## Examples

      iex> revert_tag_changes(moderator, %{"ids" => ["12", "13"]})
      {:ok, [%TagChange{}, %TagChange{}]}

  """
  @spec revert_tag_changes(Actor.t(), map()) ::
          {:ok, [TagChange.t()]} | {:error, :unauthorized | Ecto.Changeset.t()}
  def revert_tag_changes(%Actor{} = actor, params) do
    with :ok <- authorize(actor, :revert, TagChange),
         {:ok, revert_form} <-
           %RevertForm{}
           |> RevertForm.changeset(params)
           |> Ecto.Changeset.apply_action(:create),
         {:ok, tag_changes} <-
           revert_ids(revert_form.ids, %{
             ip: actor.ip,
             fingerprint: actor.fingerprint,
             user_id: actor.user.id
           }) do
      ModerationLogs.create_moderation_log(
        actor,
        "TagChange.Revert:create",
        Paths.profile_path(actor.user),
        "Reverted #{length(tag_changes)} tag changes"
      )

      {:ok, tag_changes}
    end
  end

  @doc """
  Reverts a validated worker batch without request authorization or logging.

  The worker owns batching by image ID. Missing IDs and hidden-image changes are
  skipped; database failures are returned to the worker.

  ## Examples

      iex> revert_for_worker([12, 13], attributes)
      {:ok, [%TagChange{}, %TagChange{}]}

  """
  @spec revert_for_worker([IntegerId.integer_id()], map()) ::
          {:ok, [TagChange.t()]} | {:error, Ecto.Changeset.t()}
  def revert_for_worker(ids, attributes) do
    with {:ok, revert_form} <-
           %RevertForm{}
           |> RevertForm.changeset(%{ids: ids})
           |> Ecto.Changeset.apply_action(:create) do
      revert_ids(revert_form.ids, attributes)
    end
  end

  @doc """
  Deletes the tag change named by `id` and its moderation audit atomically.

  Loading precedes `:delete` authorization, so malformed and absent IDs are
  always not found while a real forbidden row is unauthorized. Anonymous
  changes use an explicit author label in the log. The search document is
  deleted only after the database transaction commits.

  ## Examples

      iex> delete_tag_change(moderator, "42")
      {:ok, %TagChange{}}

      iex> delete_tag_change(actor, "missing")
      {:error, :not_found}

  """
  @spec delete_tag_change(Actor.t(), IntegerId.integer_id()) ::
          {:ok, TagChange.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def delete_tag_change(%Actor{} = actor, id) do
    with {:ok, tag_change} <-
           TagChange
           |> preload([:user, :image, tags: [:tag]])
           |> Loader.fetch_and_authorize(actor, :delete, id) do
      author = if tag_change.user, do: tag_change.user.name, else: "an anonymous user"

      Multi.new()
      |> Multi.delete(:tag_change, tag_change)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "TagChange:delete",
        Paths.image_path(tag_change.image),
        "Deleted tag change by #{author} containing #{length(tag_change.tags)} tags on image #{tag_change.image_id} from history"
      )
      |> Multi.on_commit(fn %{tag_change: tag_change} ->
        Search.delete_document(tag_change.id, TagChange)
      end)
      |> Multi.transact()
      |> case do
        {:ok, %{tag_change: %TagChange{} = tag_change}} ->
          {:ok, tag_change}

        {:error, :tag_change, %Ecto.Changeset{} = changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Deletes tag-change rows left empty by tag deletion and removes their search
  documents.

  Returns `{count, ids}` using the database's explicit `RETURNING id` result.

  ## Examples

      iex> cleanup_empty_for_tag_deletion()
      {2, [12, 13]}

  """
  @spec cleanup_empty_for_tag_deletion() :: {non_neg_integer(), [integer()]}
  def cleanup_empty_for_tag_deletion do
    empty_changes =
      TagChange
      |> from(as: :tag_change)
      |> where(
        not exists(where(TagChanges.Tag, [tag], tag.tag_change_id == parent_as(:tag_change).id))
      )
      |> select([tag_change], tag_change.id)

    {count, tag_change_ids} = Repo.delete_all(empty_changes)
    Enum.each(tag_change_ids, &Search.delete_document(&1, TagChange))

    {count, tag_change_ids}
  end

  @doc """
  Counts tag-change batches and changed tags for an already-loaded image.

  ## Examples

      iex> count_for_image(image)
      {3, 7}

  """
  @spec count_for_image(Image.t()) :: {non_neg_integer(), non_neg_integer()}
  def count_for_image(%Image{id: image_id}) do
    TagChange
    |> where(image_id: ^image_id)
    |> join(:left, [tag_change], tag in assoc(tag_change, :tags))
    |> select([tag_change, tag], {count(tag_change, :distinct), count(tag)})
    |> Repo.one()
  end

  @doc """
  Updates tag-change search documents after a user rename.

  ## Examples

      iex> user_name_reindex("old name", "new name")
      :ok

  """
  @spec user_name_reindex(String.t(), String.t()) :: term()
  def user_name_reindex(old_name, new_name) do
    data = SearchIndex.user_name_update_by_query(old_name, new_name)
    Search.update_by_query(TagChange, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Queues every tag change associated with `image_ids` for worker reindexing.

  ## Examples

      iex> reindex_for_images([12, 13])
      [12, 13]

  """
  @spec reindex_for_images([integer()]) :: [integer()]
  def reindex_for_images(image_ids) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["TagChanges", "image_id", image_ids])
    image_ids
  end

  @doc """
  Returns the association projection required to serialize tag-change search
  documents.

  ## Examples

      iex> indexing_preloads()
      [image: image_query, tags: [tag: tag_query], user: user_query]

  """
  @spec indexing_preloads() :: list()
  def indexing_preloads do
    alias_tags_query = select(Tag, [:aliased_tag_id, :name])

    base_tags_query =
      Tag
      |> select([:id, :name])
      |> preload(aliases: ^alias_tags_query)

    image_query = select(Image, [:anonymous, :hidden_from_users, :user_id])

    [
      image: image_query,
      tags: [tag: base_tags_query],
      user: select(User, [:name])
    ]
  end

  @doc """
  Worker entry point for reindexing tag changes matching `column` and
  `condition`.

  ## Examples

      iex> perform_reindex(:id, [12, 13])
      :ok

  """
  @spec perform_reindex(atom(), [term()]) :: term()
  def perform_reindex(column, condition) do
    TagChange
    |> preload(^indexing_preloads())
    |> where([tag_change], field(tag_change, ^column) in ^condition)
    |> Search.reindex(TagChange)
  end

  @doc """
  Worker service that reverts every tag change selected by `queryable`, batching
  only on image IDs so one image's history cannot straddle a batch boundary.

  ## Examples

      iex> revert_all_for_worker(query, %{batch_size: 100})
      :ok

  """
  @spec revert_all_for_worker(Ecto.Queryable.t(), map()) :: :ok | {:error, term()}
  def revert_all_for_worker(queryable, attributes) do
    batch_size = attributes[:batch_size] || 100
    attributes = Map.delete(attributes, :batch_size)

    queryable
    |> Batch.query_batches(batch_size: batch_size, id_field: :image_id)
    |> Enum.reduce_while(:ok, fn queryable, :ok ->
      queryable
      |> select([tag_change], tag_change.id)
      |> Repo.all()
      |> revert_for_worker(attributes)
      |> case do
        {:ok, _tag_changes} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end
end
