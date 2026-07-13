defmodule Philomena.Filters do
  @moduledoc """
  The Filters context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]
  alias Philomena.Repo

  alias Philomena.Filters.Filter
  alias Philomena.Filters.FilterPage
  alias Philomena.Filters.Query
  alias Philomena.Filters
  alias Philomena.Attribution.Actor
  alias Philomena.IntegerId
  alias Philomena.Schema.TagList
  alias Philomena.Tags.Tag
  alias Philomena.Users
  alias Philomena.Users.User
  alias PhilomenaQuery.Search
  alias Philomena.IndexWorker

  @doc """
  Returns the list of filters.

  ## Examples

      iex> list_filters()
      [%Filter{}, ...]

  """
  def list_filters do
    Repo.all(Filter)
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
  Returns the filters shown on the index for `user`: the viewer's own filters
  (empty for an anonymous visitor) and the system filters, each with `:user`
  preloaded.

  ## Examples

      iex> index_filters(user)
      {[%Filter{}, ...], [%Filter{}, ...]}

  """
  @spec index_filters(User.t() | nil) :: {[Filter.t()], [Filter.t()]}
  def index_filters(user) do
    my_filters =
      if user do
        Filter
        |> where(user_id: ^user.id)
        |> preload(:user)
        |> Repo.all()
      else
        []
      end

    system_filters =
      Filter
      |> where(system: true)
      |> preload(:user)
      |> Repo.all()

    {my_filters, system_filters}
  end

  @doc """
  Loads the filter named by `id` for the JSON API on behalf of `user`.

  Parses `id`, loads the matching filter with `:user` preloaded, and authorizes
  `:show` (public and system filters are visible to everyone; private filters
  only to their owner). Every lookup and authorization failure collapses to
  `{:error, :not_found}`, so a non-castable `id`, an unknown `id`, and a filter
  the viewer may not see are indistinguishable.

  Returns `{:ok, %Filter{}}` or `{:error, :not_found}`.

  ## Examples

      iex> api_show_filter(user, "1")
      {:ok, %Filter{}}

      iex> api_show_filter(user, "not-a-number")
      {:error, :not_found}

  """
  @spec api_show_filter(User.t() | nil, any()) :: {:ok, Filter.t()} | {:error, :not_found}
  def api_show_filter(user, id) do
    case IntegerId.parse(id) do
      :error ->
        {:error, :not_found}

      {:ok, id} ->
        filter =
          Filter
          |> where(id: ^id)
          |> preload(:user)
          |> Repo.one()

        case authorize(user, :show, filter) do
          :ok -> {:ok, filter}
          _error -> {:error, :not_found}
        end
    end
  end

  @doc """
  Returns the page of system filters for the JSON API.

  Selects filters flagged `system: true`, ordered by ascending id, paginated by
  `pagination`.

  ## Examples

      iex> api_system_filters(pagination)
      %Scrivener.Page{}

  """
  @spec api_system_filters(map()) :: Scrivener.Page.t()
  def api_system_filters(pagination) do
    Filter
    |> where(system: true)
    |> order_by(asc: :id)
    |> Repo.paginate(pagination)
  end

  @doc """
  Returns the page of `user`'s own filters for the JSON API.

  Selects filters owned by `user`, ordered by ascending id, paginated by
  `pagination`. System filters and other users' filters are excluded.

  ## Examples

      iex> api_user_filters(user, pagination)
      %Scrivener.Page{}

  """
  @spec api_user_filters(User.t(), map()) :: Scrivener.Page.t()
  def api_user_filters(user, pagination) do
    Filter
    |> where(user_id: ^user.id)
    |> order_by(asc: :id)
    |> Repo.paginate(pagination)
  end

  @doc """
  Runs the filter search that `query_string` describes on behalf of `user`.

  Compiles `query_string` against the filter search index (the `my` field is
  available only to a signed-in `user`) and restricts results to filters the
  viewer may see: public filters, system filters, and the viewer's own.
  Results are sorted by name then descending id, paginated by `pagination`, and
  loaded with `:user` preloaded.

  Returns `{:ok, %Scrivener.Page{}}`, or the compiler's `{:error, msg}` for a
  malformed query.

  ## Examples

      iex> search_filters(user, "name:test", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_filters(user, "name:(", pagination)
      {:error, "There was an error parsing your query."}

  """
  @spec search_filters(User.t() | nil, String.t(), map()) ::
          {:ok, Scrivener.Page.t()} | {:error, String.t()}
  def search_filters(user, query_string, pagination) do
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
  Assembles the filter show page named by `id` for `user`.

  Loads the filter with `:user` preloaded and authorizes `:show` (public and
  system filters are visible to everyone; private filters only to their owner).
  Loads the filter's spoilered and hidden tags, each ordered by name. A
  non-castable `id` is `{:error, :not_found}`; a well-formed unknown `id` the
  actor may act on (an admin) is `{:error, :not_found}`, otherwise
  `{:error, :unauthorized}`.

  Returns `{:ok, %FilterPage{}}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_filter_page(user, "1")
      {:ok, %FilterPage{}}

  """
  @spec load_filter_page(User.t() | nil, any()) ::
          {:ok, FilterPage.t()} | {:error, :not_found | :unauthorized}
  def load_filter_page(user, id) do
    with {:ok, filter} <- load_and_authorize_filter(user, id, :show, [:user]) do
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
  Builds the changeset for a new filter on behalf of `user`.

  Authorizes `:create` (permitted for any signed-in user). When `based_on` names
  a filter the viewer may see (public, system, or their own), the new filter is
  prefilled from it as an unpersisted record; an unknown or omitted `based_on`
  yields a blank form.

  Returns `{:ok, %Ecto.Changeset{}}` or `{:error, :unauthorized}`.

  ## Examples

      iex> new_filter(user, nil)
      {:ok, %Ecto.Changeset{}}

      iex> new_filter(user, "1")
      {:ok, %Ecto.Changeset{}}

  """
  @spec new_filter(User.t() | nil, any()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_filter(user, based_on) do
    with :ok <- authorize(user, :new, Filter) do
      {:ok, change_filter(base_filter(user, based_on))}
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
  Loads the filter named by `id` for editing on behalf of `user`.

  Authorizes `:edit` (its owner only) and assigns the spoilered and hidden tag
  lists onto the filter for the form. A non-castable `id` is
  `{:error, :not_found}`; a well-formed unknown `id` the actor may act on (an
  admin) is `{:error, :not_found}`, otherwise `{:error, :unauthorized}`.

  Returns `{:ok, {%Filter{}, %Ecto.Changeset{}}}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_filter_for_edit(user, "1")
      {:ok, {%Filter{}, %Ecto.Changeset{}}}

  """
  @spec load_filter_for_edit(User.t() | nil, any()) ::
          {:ok, {Filter.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_filter_for_edit(user, id) do
    with {:ok, filter} <- load_and_authorize_filter(user, id, :edit) do
      filter =
        filter
        |> TagList.assign_tag_list(:spoilered_tag_ids, :spoilered_tag_list)
        |> TagList.assign_tag_list(:hidden_tag_ids, :hidden_tag_list)

      {:ok, {filter, change_filter(filter)}}
    end
  end

  @doc """
  Switches `user`'s current filter to the one named by `id`.

  Loads the filter named by `id` and, when the viewer may not see it (a private
  filter belonging to someone else), substitutes the default filter. For a
  signed-in `user` the choice is persisted to their account; for an anonymous
  visitor the resolved filter is returned for the caller to store in a cookie.
  A well-formed unknown `id` is `{:error, :not_found}`; a missing `id` reaches
  the query layer, which rejects a nil comparison.

  Returns `{:ok, %Filter{}}` (the filter actually switched to) or
  `{:error, :not_found}`.

  ## Examples

      iex> switch_current_filter(user, "1")
      {:ok, %Filter{}}

  """
  @spec switch_current_filter(User.t() | nil, any()) ::
          {:ok, Filter.t()} | {:error, :not_found}
  def switch_current_filter(user, id) do
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
  Gets a single filter.

  Raises `Ecto.NoResultsError` if the Filter does not exist.

  ## Examples

      iex> get_filter!(123)
      %Filter{}

      iex> get_filter!(456)
      ** (Ecto.NoResultsError)

  """
  def get_filter!(id), do: Repo.get!(Filter, id)

  @doc """
  Creates a filter owned by `user`.

  Authorizes `:create` (permitted for any signed-in user), then inserts the
  filter and queues it for reindexing.

  Returns `{:ok, %Filter{}}`, `{:error, %Ecto.Changeset{}}` on invalid input, or
  `{:error, :unauthorized}` for an anonymous actor.

  ## Examples

      iex> create_filter(user, %{field: value})
      {:ok, %Filter{}}

      iex> create_filter(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_filter(User.t() | nil, map()) ::
          {:ok, Filter.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized}
  def create_filter(user, attrs \\ %{}) do
    with :ok <- authorize(user, :create, Filter) do
      %Filter{user_id: user.id}
      |> Filter.creation_changeset(attrs)
      |> Repo.insert()
      |> reindex_after_update()
    end
  end

  @doc """
  Updates a filter.

  ## Examples

      iex> update_filter(filter, %{field: new_value})
      {:ok, %Filter{}}

      iex> update_filter(filter, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_filter(%Filter{} = filter, attrs) do
    filter
    |> Filter.update_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Updates the filter named by `id` on behalf of `user`.

  Loads the filter, authorizes `:update` (its owner only), then applies `attrs`.
  A non-castable `id` is `{:error, :not_found}`; a well-formed unknown `id` the
  actor may act on (an admin) is `{:error, :not_found}`, otherwise
  `{:error, :unauthorized}`.

  Returns `{:ok, %Filter{}}`, `{:error, %Ecto.Changeset{}}` on invalid input,
  `{:error, :not_found}`, or `{:error, :unauthorized}`.

  ## Examples

      iex> update_filter(user, "1", %{"name" => "Renamed"})
      {:ok, %Filter{}}

  """
  @spec update_filter(User.t() | nil, any(), map()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def update_filter(user, id, attrs) do
    with {:ok, filter} <- load_and_authorize_filter(user, id, :update) do
      update_filter(filter, attrs)
    end
  end

  @doc """
  Makes a filter public.

  Updates the filter to be publicly accessible by other users.

  ## Examples

      iex> make_filter_public(filter)
      {:ok, %Filter{}}

  """
  def make_filter_public(%Filter{} = filter) do
    filter
    |> Filter.public_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Makes the filter named by `id` public on behalf of `user`.

  Loads the filter, authorizes `:edit` (its owner only), then makes it public.
  A non-castable `id` is `{:error, :not_found}`; a well-formed unknown `id` the
  actor may act on (an admin) is `{:error, :not_found}`, otherwise
  `{:error, :unauthorized}`.

  Returns `{:ok, %Filter{}}`, `{:error, %Ecto.Changeset{}}`,
  `{:error, :not_found}`, or `{:error, :unauthorized}`.

  ## Examples

      iex> make_filter_public(user, "1")
      {:ok, %Filter{}}

  """
  @spec make_filter_public(User.t() | nil, any()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def make_filter_public(user, id) do
    with {:ok, filter} <- load_and_authorize_filter(user, id, :edit) do
      make_filter_public(filter)
    end
  end

  @doc """
  Deletes a Filter.

  ## Examples

      iex> delete_filter(filter)
      {:ok, %Filter{}}

      iex> delete_filter(filter)
      {:error, %Ecto.Changeset{}}

  """
  def delete_filter(%Filter{} = filter) do
    filter
    |> Filter.deletion_changeset()
    |> Repo.delete()
    |> case do
      {:ok, filter} ->
        unindex_filter(filter)

        {:ok, filter}

      error ->
        error
    end
  end

  @doc """
  Deletes the filter named by `id` on behalf of `user`.

  Loads the filter, authorizes `:delete` (its owner only), then deletes it.
  A filter still referenced as a current filter fails the foreign-key
  constraint and comes back `{:error, %Ecto.Changeset{}}`, its `data` carrying
  the filter. A non-castable `id` is `{:error, :not_found}`; a well-formed
  unknown `id` the actor may act on (an admin) is `{:error, :not_found}`,
  otherwise `{:error, :unauthorized}`.

  Returns `{:ok, %Filter{}}`, `{:error, %Ecto.Changeset{}}`,
  `{:error, :not_found}`, or `{:error, :unauthorized}`.

  ## Examples

      iex> delete_filter(user, "1")
      {:ok, %Filter{}}

  """
  @spec delete_filter(User.t() | nil, any()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :unauthorized}
  def delete_filter(user, id) do
    with {:ok, filter} <- load_and_authorize_filter(user, id, :delete) do
      delete_filter(filter)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking filter changes.

  ## Examples

      iex> change_filter(filter)
      %Ecto.Changeset{source: %Filter{}}

  """
  def change_filter(%Filter{} = filter) do
    Filter.changeset(filter, %{})
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
  Adds a tag to a filter's hidden tags list.

  Updates the filter to hide content with the specified tag.

  ## Examples

      iex> hide_tag(filter, tag)
      {:ok, %Filter{}}

  """
  def hide_tag(filter, tag) do
    hidden_tag_ids = Enum.uniq([tag.id | filter.hidden_tag_ids])

    filter
    |> Filter.hidden_tags_changeset(hidden_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Removes a tag from a filter's hidden tags list.

  ## Examples

      iex> unhide_tag(filter, tag)
      {:ok, %Filter{}}

  """
  def unhide_tag(filter, tag) do
    hidden_tag_ids = filter.hidden_tag_ids -- [tag.id]

    filter
    |> Filter.hidden_tags_changeset(hidden_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Adds a tag to a filter's spoilered tags list.

  ## Examples

      iex> spoiler_tag(filter, tag)
      {:ok, %Filter{}}

  """
  def spoiler_tag(filter, tag) do
    spoilered_tag_ids = Enum.uniq([tag.id | filter.spoilered_tag_ids])

    filter
    |> Filter.spoilered_tags_changeset(spoilered_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Removes a tag from a filter's spoilered tags list.

  ## Examples

      iex> unspoiler_tag(filter, tag)
      {:ok, %Filter{}}

  """
  def unspoiler_tag(filter, tag) do
    spoilered_tag_ids = filter.spoilered_tag_ids -- [tag.id]

    filter
    |> Filter.spoilered_tags_changeset(spoilered_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Adds the tag named by `tag_slug` to `current_filter`'s hidden tags on behalf
  of `actor`.

  Rejects a banned actor (`{:error, :ban}`) or one without a fingerprint
  (`{:error, :unauthorized}`), then authorizes `:edit` on `current_filter` (its
  owner only). An unknown `tag_slug` is `{:error, :not_found}`.

  Returns `{:ok, %Filter{}}`, `{:error, %Ecto.Changeset{}}`, `{:error, :ban}`,
  `{:error, :not_found}`, or `{:error, :unauthorized}`.
  """
  @spec hide_tag(Actor.t(), Filter.t(), any()) ::
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
  @spec unhide_tag(Actor.t(), Filter.t(), any()) ::
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
  @spec spoiler_tag(Actor.t(), Filter.t(), any()) ::
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
  @spec unspoiler_tag(Actor.t(), Filter.t(), any()) ::
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
  defp load_and_authorize_filter(user, id, action, preloads \\ []) do
    case IntegerId.parse(id) do
      :error ->
        {:error, :not_found}

      {:ok, id} ->
        filter = Filter |> preload(^preloads) |> Repo.get(id)

        with :ok <- authorize(user, action, filter),
             %Filter{} <- filter do
          {:ok, filter}
        else
          {:error, :unauthorized} -> {:error, :unauthorized}
          nil -> {:error, :not_found}
        end
    end
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
  Removes a filter from the search index.

  ## Examples

      iex> unindex_filter(filter)
      %Filter{}

  """
  def unindex_filter(%Filter{} = filter) do
    Search.delete_document(filter.id, Filter)

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
