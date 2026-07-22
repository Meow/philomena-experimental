defmodule Philomena.Filters do
  @moduledoc """
  The Filters context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]
  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Filters.Filter
  alias Philomena.Filters.FilterPage
  alias Philomena.Filters.Query
  alias Philomena.Filters
  alias Philomena.Attribution.Actor
  alias Philomena.IntegerId
  alias Philomena.Schema.TagList
  alias Philomena.Tags.Tag
  alias Philomena.Users
  alias PhilomenaQuery.Search
  alias Philomena.IndexWorker

  # Creates a filter.
  defp create_loaded_filter(user, attrs) do
    %Filter{user_id: user.id}
    |> Filter.creation_changeset(attrs)
    |> Repo.insert()
    |> reindex_after_update()
  end

  # Updates a filter.
  defp update_filter(%Filter{} = filter, attrs) do
    filter
    |> Filter.update_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Makes a filter public.
  defp make_filter_public(%Filter{} = filter) do
    filter
    |> Filter.public_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  # Adds a tag to a filter's hidden tags list.
  # Visible for testing.
  @doc false
  def hide_tag(%Filter{} = filter, tag) do
    hidden_tag_ids = Enum.uniq([tag.id | filter.hidden_tag_ids])

    filter
    |> Filter.hidden_tags_changeset(hidden_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Removes a tag from a filter's hidden tags list.
  # Visible for testing.
  @doc false
  def unhide_tag(%Filter{} = filter, tag) do
    hidden_tag_ids = filter.hidden_tag_ids -- [tag.id]

    filter
    |> Filter.hidden_tags_changeset(hidden_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Adds a tag to a filter's spoilered tags list.
  # Visible for testing.
  @doc false
  def spoiler_tag(%Filter{} = filter, tag) do
    spoilered_tag_ids = Enum.uniq([tag.id | filter.spoilered_tag_ids])

    filter
    |> Filter.spoilered_tags_changeset(spoilered_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Removes a tag from a filter's spoilered tags list.
  # Visible for testing.
  @doc false
  def unspoiler_tag(%Filter{} = filter, tag) do
    spoilered_tag_ids = filter.spoilered_tag_ids -- [tag.id]

    filter
    |> Filter.spoilered_tags_changeset(spoilered_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Deletes a filter.
  defp delete_filter(%Filter{} = filter) do
    filter
    |> Filter.deletion_changeset()
    |> Repo.delete()
    |> case do
      {:ok, filter} ->
        Search.delete_document(filter.id, Filter)

        {:ok, filter}

      error ->
        error
    end
  end

  # Returns an `%Ecto.Changeset{}` for tracking filter changes.
  # Visible for testing.
  @doc false
  def change_filter(%Filter{} = filter) do
    Filter.changeset(filter, %{})
  end

  @doc """
  Returns the default filter.

  ## Examples

      iex> default_filter()
      %Filter{}

  """
  def default_filter do
    Filter
    |> where(system: true, name: "Default")
    |> Repo.one!()
  end

  @doc """
  Returns the filters listed for `user`: the viewer's own filters
  (empty for an anonymous visitor) and the system filters, each with `:user`
  preloaded.

  ## Examples

      iex> index_filters(user)
      {[%Filter{}, ...], [%Filter{}, ...]}

  """
  @spec index_filters(Actor.t()) :: {[Filter.t()], [Filter.t()]}
  def index_filters(%Actor{user: user}) do
    my_filters =
      if user do
        user_filters_query(user)
        |> preload(:user)
        |> Repo.all()
      else
        []
      end

    system_filters =
      system_filters_query()
      |> preload(:user)
      |> Repo.all()

    {my_filters, system_filters}
  end

  @doc """
  Loads the filter named by `id` on behalf of `actor`, with `user` preloaded.

  Public and system filters are visible to everyone; private filters only to
  their owner.

  ## Examples

      iex> load_filter(user, "1")
      {:ok, %Filter{}}

      iex> load_filter(user, "not-a-number")
      {:error, :not_found}

      iex> load_filter(user, unowned_private_filter_id)
      {:error, :unauthorized}

  """
  @spec load_filter(Actor.t(), Loader.integer_id()) ::
          {:ok, Filter.t()} | {:error, :not_found | :unauthorized}
  def load_filter(%Actor{} = actor, id) do
    load_and_authorize_filter(actor, id, :show, [:user])
  end

  @doc """
  Returns the page of system filters.

  Selects filters flagged `system: true`, ordered by ascending id, paginated by
  `pagination`.

  ## Examples

      iex> system_filters(pagination)
      %Scrivener.Page{}

  """
  @spec system_filters(Repo.pagination_params()) :: Scrivener.Page.t(Filter.t())
  def system_filters(pagination) do
    system_filters_query()
    |> order_by(asc: :id)
    |> Repo.paginate(pagination)
  end

  @doc """
  Returns the page of `actor`'s own filters, ordered by ascending id, paginated
  by `pagination`.

  ## Examples

      iex> user_filters(user, pagination)
      %Scrivener.Page{}

  """
  @spec user_filters(Actor.t(), Repo.pagination_params()) :: Scrivener.Page.t(Filter.t())
  def user_filters(%Actor{user: user}, pagination) do
    user_filters_query(user)
    |> order_by(asc: :id)
    |> Repo.paginate(pagination)
  end

  defp system_filters_query, do: where(Filter, system: true)

  defp user_filters_query(user), do: where(Filter, user_id: ^user.id)

  @doc """
  Runs the filter search that `query_string` describes on behalf of `actor`.

  Compiles `query_string` against the filter search index (the `my` field is
  available only to a signed-in `user`) and restricts results to filters the
  viewer may see: public filters, system filters, and the viewer's own.
  Results are sorted by name then descending id, paginated by `pagination`, and
  loaded with `user` preloaded.

  ## Examples

      iex> search_filters(user, "name:test", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_filters(user, "name:(", pagination)
      {:error, "There was an error parsing your query."}

  """
  @spec search_filters(Actor.t(), String.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Filter.t())} | {:error, String.t()}
  def search_filters(%Actor{user: user}, query_string, pagination) do
    with {:ok, query} <- Query.compile(query_string, user: user) do
      filters =
        Filter
        |> Search.search_definition(
          %{
            query: %{
              bool: %{
                must: [query | visibility_filters(user)]
              }
            },
            sort: [
              %{name: :asc},
              %{id: :desc}
            ]
          },
          pagination
        )
        |> Search.search_records(preload(Filter, [:user]))

      {:ok, filters}
    end
  end

  defp visibility_filters(user),
    do: [%{bool: %{should: visibility_shoulds(user)}}]

  defp visibility_shoulds(nil),
    do: [%{term: %{public: true}}, %{term: %{system: true}}]

  defp visibility_shoulds(user),
    do: visibility_shoulds(nil) ++ [%{term: %{user_id: user.id}}]

  @doc """
  Assembles the filter page named by `id` for `actor`.

  Loads the filter with `actor` preloaded and authorizes `:show` (public and
  system filters are visible to everyone; private filters only to their owner).
  Loads the filter's spoilered and hidden tags, each ordered by name.

  ## Examples

      iex> load_filter_page(user, "1")
      {:ok, %FilterPage{}}

      iex> load_filter_page(user, "999999999")
      {:error, :unauthorized}

      iex> load_filter_page(admin, "999999999")
      {:error, :not_found}

  """
  @spec load_filter_page(Actor.t(), Loader.integer_id()) ::
          {:ok, FilterPage.t()} | {:error, :not_found | :unauthorized}
  def load_filter_page(%Actor{} = actor, id) do
    with {:ok, filter} <- load_filter(actor, id) do
      {:ok,
       %FilterPage{
         filter: filter,
         spoilered_tags: tags_by_ids(filter.spoilered_tag_ids),
         hidden_tags: tags_by_ids(filter.hidden_tag_ids)
       }}
    end
  end

  defp tags_by_ids(ids) do
    Tag
    |> where([t], t.id in ^ids)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Builds the changeset for a new filter on behalf of `actor`.

  Authorizes `:create` (permitted for any signed-in user). When `based_on` names
  a filter the viewer may see (public, system, or their own), the new filter is
  prefilled from it as an unpersisted record; an unknown or omitted `based_on`
  yields a blank changeset.

  ## Examples

      iex> new_filter(user, nil)
      {:ok, %Ecto.Changeset{}}

      iex> new_filter(user, "1")
      {:ok, %Ecto.Changeset{}}

      iex> new_filter(user, "999999999")
      {:error, :unauthorized}

  """
  @spec new_filter(Actor.t(), Loader.integer_id()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_filter(%Actor{} = actor, based_on) do
    with :ok <- authorize(actor, :new, Filter) do
      {:ok, change_filter(base_filter(actor.user, based_on))}
    end
  end

  defp base_filter(_user, nil), do: %Filter{}

  defp base_filter(user, based_on) do
    visible_source_filter(user, based_on)
    |> Kernel.||(%Filter{})
    |> TagList.assign_tag_list(:spoilered_tag_ids, :spoilered_tag_list)
    |> TagList.assign_tag_list(:hidden_tag_ids, :hidden_tag_list)
    |> Map.put(:__meta__, %Ecto.Schema.Metadata{
      state: :built,
      source: "filters",
      schema: Filter
    })
  end

  defp visible_source_filter(user, based_on) do
    Filter
    |> where(id: ^based_on)
    |> where([f], f.system == true or f.public == true or f.user_id == ^user.id)
    |> Repo.one()
  end

  @doc """
  Loads the filter named by `id` for editing on behalf of `actor`.

  Authorizes `:edit` (its owner only) and assigns the spoilered and hidden tag
  lists onto the filter.

  ## Examples

      iex> load_filter_for_edit(user, "1")
      {:ok, {%Filter{}, %Ecto.Changeset{}}}

      iex> load_filter_for_edit(user, "999999999")
      {:error, :unauthorized}

      iex> load_filter_for_edit(admin, "999999999")
      {:error, :not_found}

  """
  @spec load_filter_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Filter.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_filter_for_edit(%Actor{} = actor, id) do
    with {:ok, filter} <- load_and_authorize_filter(actor, id, :edit) do
      filter =
        filter
        |> TagList.assign_tag_list(:spoilered_tag_ids, :spoilered_tag_list)
        |> TagList.assign_tag_list(:hidden_tag_ids, :hidden_tag_list)

      {:ok, {filter, change_filter(filter)}}
    end
  end

  @doc """
  Switches `actor`'s current filter to the one named by `id`.

  Loads the filter named by `id` and, when the viewer may not see it (a private
  filter belonging to someone else), substitutes the default filter. The resolved
  filter is returned for the caller to store. For a signed-in `user`, the choice
  is also persisted to their account;

  ## Examples

      iex> switch_current_filter(user, "1")
      {:ok, %Filter{}}

      iex> switch_current_filter(user, "999999999")
      {:error, :not_found}

      iex> switch_current_filter(user, nil)
      ** (ArgumentError) nil given for :id

  """
  @spec switch_current_filter(Actor.t(), Loader.integer_id()) ::
          {:ok, Filter.t()} | {:error, :not_found}
  def switch_current_filter(%Actor{user: user}, id) do
    case filter_for_switch(id) do
      nil ->
        {:error, :not_found}

      %Filter{} = filter ->
        filter = visible_or_default(user, filter)
        persist_current_filter(user, filter)
        {:ok, filter}
    end
  end

  # A missing id reaches the query layer, which rejects a nil comparison; a
  # non-castable id can never name a row.
  # FIXME this is nonsense, get rid of this behavior
  defp filter_for_switch(nil), do: Repo.get_by(Filter, id: nil)

  defp filter_for_switch(id) do
    case IntegerId.parse(id) do
      {:ok, id} -> Repo.get(Filter, id)
      :error -> nil
    end
  end

  defp visible_or_default(user, filter) do
    case authorize(user, :show, filter) do
      :ok -> filter
      _error -> default_filter()
    end
  end

  defp persist_current_filter(nil, _filter), do: :ok

  defp persist_current_filter(user, filter) do
    {:ok, _user} = Users.update_filter(user, filter)
    :ok
  end

  @doc """
  Creates a filter owned by `actor`.

  Authorizes `:create` (permitted for any signed-in user), then inserts the
  filter and queues it for reindexing.

  ## Examples

      iex> create_filter(user, %{field: value})
      {:ok, %Filter{}}

      iex> create_filter(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

      iex> create_filter(anon, %{field: value})
      {:error, :unauthorized}

  """
  @spec create_filter(Actor.t(), map()) ::
          {:ok, Filter.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def create_filter(%Actor{user: user} = actor, attrs \\ %{}) do
    with :ok <- authorize(actor, :create, Filter) do
      create_loaded_filter(user, attrs)
    end
  end

  @doc """
  Updates the filter named by `id` on behalf of `actor`.

  Loads the filter, authorizes `:update` (its owner only), then applies `attrs`.

  ## Examples

      iex> update_filter(user, "1", %{"name" => "Renamed"})
      {:ok, %Filter{}}

      iex> update_filter(user, "1", invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_filter(user, "999999999", filter_params)
      {:error, :unauthorized}

      iex> update_filter(admin, "999999999", filter_params)
      {:error, :not_found}

  """
  @spec update_filter(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def update_filter(%Actor{} = actor, id, attrs) do
    with {:ok, filter} <- load_and_authorize_filter(actor, id, :update) do
      update_filter(filter, attrs)
    end
  end

  @doc """
  Makes the filter named by `id` public on behalf of `actor`.

  Loads the filter, authorizes `:edit` (its owner only), then makes it public.

  ## Examples

      iex> make_filter_public(user, "1")
      {:ok, %Filter{}}

      iex> make_filter_public(user, unowned_filter_id)
      {:error, :unauthorized}

      iex> make_filter_public(admin, "999999999")
      {:error, :not_found}

  """
  @spec make_filter_public(Actor.t(), Loader.integer_id()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def make_filter_public(%Actor{} = actor, id) do
    with {:ok, filter} <- load_and_authorize_filter(actor, id, :edit) do
      make_filter_public(filter)
    end
  end

  @doc """
  Deletes the filter named by `id` on behalf of `actor`.

  Loads the filter, authorizes `:delete` (its owner only), then deletes it.
  (A filter still referenced as a user's current filter fails the foreign-key
  constraint and is not deleted.)

  ## Examples

      iex> delete_filter(user, "1")
      {:ok, %Filter{}}

      iex> delete_filter(user, "999999999")
      {:error, :unauthorized}

      iex> delete_filter(admin, "999999999")
      {:error, :not_found}

  """
  @spec delete_filter(Actor.t(), Loader.integer_id()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def delete_filter(%Actor{} = actor, id) do
    with {:ok, filter} <- load_and_authorize_filter(actor, id, :delete) do
      delete_filter(filter)
    end
  end

  @doc """
  Returns a grouped list of recent and user filters.

  Takes a user and returns a list of their recently used filters and personal filters,
  grouped into "Recent Filters" and "Your Filters" categories.

  ## Examples

      iex> recent_and_user_filters(user)
      [
        {"Recent Filters", [[key: "Filter 1", value: 1], ...]},
        {"Your Filters", [[key: "Filter 2", value: 2], ...]}
      ]

  """
  def recent_and_user_filters(user) do
    recent_filter_ids =
      [user.current_filter_id | user.recent_filter_ids]
      |> Enum.take(10)

    user_filters =
      Filter
      |> select([f], %{id: f.id, name: f.name, recent: ^"f"})
      |> where(user_id: ^user.id)
      |> limit(10)

    recent_filters =
      Filter
      |> select([f], %{id: f.id, name: f.name, recent: ^"t"})
      |> where([f], f.id in ^recent_filter_ids)

    union_all(recent_filters, ^user_filters)
    |> Repo.all()
    |> Enum.sort_by(fn f ->
      Enum.find_index(user.recent_filter_ids, fn id -> f.id == id end)
    end)
    |> Enum.group_by(
      fn
        %{recent: "t"} -> "Recent Filters"
        _user -> "Your Filters"
      end,
      fn %{id: id, name: name} ->
        [key: name, value: id]
      end
    )
    |> Enum.to_list()
    |> Enum.reverse()
  end

  @doc """
  Adds the tag named by `tag_slug` to `current_filter`'s hidden tags on behalf
  of `actor`.

  Rejects a banned actor or one without a fingerprint, then authorizes `:edit`
  on `current_filter` (actor must own the current filter).

  ## Examples

      iex> hide_tag(user, filter, tag_slug)
      {:ok, %Filter{}}

      iex> hide_tag(banned_user, filter, tag_slug)
      {:error, :ban}

      iex> hide_tag(user, filter, unknown_tag_slug)
      {:error, :not_found}

      iex> hide_tag(user, unowned_filter, tag_slug)
      {:error, :unauthorized}

  """
  @spec hide_tag(Actor.t(), Filter.t(), String.t()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def hide_tag(%Actor{} = actor, current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, current_filter, tag_slug) do
      hide_tag(current_filter, tag)
    end
  end

  @doc """
  Removes the tag named by `tag_slug` from `current_filter`'s hidden tags on
  behalf of `actor`. Same authorization and return shapes as `hide_tag/3`.
  """
  @spec unhide_tag(Actor.t(), Filter.t(), String.t()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def unhide_tag(%Actor{} = actor, current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, current_filter, tag_slug) do
      unhide_tag(current_filter, tag)
    end
  end

  @doc """
  Adds the tag named by `tag_slug` to `current_filter`'s spoilered tags on
  behalf of `actor`. Same authorization and return shapes as `hide_tag/3`.
  """
  @spec spoiler_tag(Actor.t(), Filter.t(), String.t()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def spoiler_tag(%Actor{} = actor, current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, current_filter, tag_slug) do
      spoiler_tag(current_filter, tag)
    end
  end

  @doc """
  Removes the tag named by `tag_slug` from `current_filter`'s spoilered tags on
  behalf of `actor`. Same authorization and return shapes as `hide_tag/3`.
  """
  @spec unspoiler_tag(Actor.t(), Filter.t(), String.t()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def unspoiler_tag(%Actor{} = actor, current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, current_filter, tag_slug) do
      unspoiler_tag(current_filter, tag)
    end
  end

  # Ban check, then filter-edit authorization, then tag load - the order the
  # filter tag toggles are guarded in.
  defp authorize_filter_tag(actor, current_filter, tag_slug) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :edit, current_filter) do
      fetch_tag_by_slug(tag_slug)
    end
  end

  defp fetch_tag_by_slug(slug) do
    case Repo.get_by(Tag, slug: slug) do
      nil -> {:error, :not_found}
      %Tag{} = tag -> {:ok, tag}
    end
  end

  # Parses the id, loads the filter, and authorizes `action` on it. A
  # non-castable id is not-found; a well-formed unknown id is authorized as a
  # nil load, so an admin sees not-found and everyone else unauthorized.
  defp load_and_authorize_filter(actor, id, action, preloads \\ []) do
    Loader.fetch_and_authorize(Filter, actor, action, id, preloads)
  end

  defp reindex_after_update(result) do
    case result do
      {:ok, filter} ->
        reindex_filter(filter)

        {:ok, filter}

      error ->
        error
    end
  end

  @doc """
  Updates filter indexes when a user's name changes.

  Updates search indexes to reflect a user's new name.

  ## Examples

      iex> user_name_reindex("old_name", "new_name")
      :ok

  """
  def user_name_reindex(old_name, new_name) do
    data = Filters.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Filter, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Queues a single filter for search index updates.
  Returns the filter struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_filter(filter)
      %Filter{}

  """
  def reindex_filter(%Filter{} = filter) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Filters", "id", [filter.id]])

    filter
  end

  @doc """
  Returns a list of associations to preload when indexing filters.

  ## Examples

      iex> indexing_preloads()
      [:user]

  """
  def indexing_preloads do
    [:user]
  end

  @doc """
  Performs a search reindex operation on filters matching the given criteria.

  ## Parameters
  - column: The database column to filter on (e.g., :id)
  - condition: A list of values to match against the column

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      {:ok, [%Filter{}, ...]}

  """
  def perform_reindex(column, condition) do
    Filter
    |> preload(^indexing_preloads())
    |> where([f], field(f, ^column) in ^condition)
    |> Search.reindex(Filter)
  end
end
