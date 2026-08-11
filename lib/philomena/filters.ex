defmodule Philomena.Filters do
  @moduledoc """
  Image filters, viewer filter selection, and personal tag hide/spoiler settings.
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
  alias Philomena.Users.User
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
  defp persist_filter_update(%Filter{} = filter, attrs) do
    filter
    |> Filter.update_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Makes a filter public.
  defp persist_filter_publication(%Filter{} = filter) do
    filter
    |> Filter.public_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  defp persist_hidden_tag(%Filter{} = filter, %Tag{} = tag) do
    hidden_tag_ids = Enum.uniq([tag.id | filter.hidden_tag_ids])

    filter
    |> Filter.hidden_tags_changeset(hidden_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  defp persist_unhidden_tag(%Filter{} = filter, %Tag{} = tag) do
    hidden_tag_ids = filter.hidden_tag_ids -- [tag.id]

    filter
    |> Filter.hidden_tags_changeset(hidden_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  defp persist_spoilered_tag(%Filter{} = filter, %Tag{} = tag) do
    spoilered_tag_ids = Enum.uniq([tag.id | filter.spoilered_tag_ids])

    filter
    |> Filter.spoilered_tags_changeset(spoilered_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  defp persist_unspoilered_tag(%Filter{} = filter, %Tag{} = tag) do
    spoilered_tag_ids = filter.spoilered_tag_ids -- [tag.id]

    filter
    |> Filter.spoilered_tags_changeset(spoilered_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  # Deletes a filter.
  defp persist_filter_deletion(%Filter{} = filter) do
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

  defp change_filter(%Filter{} = filter) do
    Filter.changeset(filter, %{})
  end

  defp system_filters_query, do: where(Filter, system: true)

  defp user_filters_query(user), do: where(Filter, user_id: ^user.id)

  defp visibility_filters(actor) do
    case authorize(actor, :search_all, Filter) do
      :ok -> [%{match_all: %{}}]
      {:error, :unauthorized} -> [%{bool: %{should: visibility_shoulds(actor.user)}}]
    end
  end

  defp visibility_shoulds(nil),
    do: [%{term: %{public: true}}, %{term: %{system: true}}]

  defp visibility_shoulds(user),
    do: visibility_shoulds(nil) ++ [%{term: %{user_id: user.id}}]

  defp tags_by_ids(ids) do
    Tag
    |> where([t], t.id in ^ids)
    |> order_by(asc: :name)
    |> Repo.all()
  end

  defp base_filter(_actor, nil), do: %Filter{}

  defp base_filter(actor, based_on) do
    visible_source_filter(actor, based_on)
    |> Kernel.||(%Filter{})
    |> TagList.assign_tag_list(:spoilered_tag_ids, :spoilered_tag_list)
    |> TagList.assign_tag_list(:hidden_tag_ids, :hidden_tag_list)
    |> Map.put(:__meta__, %Ecto.Schema.Metadata{
      state: :built,
      source: "filters",
      schema: Filter
    })
  end

  defp visible_source_filter(actor, based_on) do
    case load_and_authorize_filter(actor, based_on, :show) do
      {:ok, filter} -> filter
      {:error, _reason} -> nil
    end
  end

  # Ban check, then filter-edit authorization, then tag load - the order the
  # filter tag toggles are guarded in.
  defp authorize_filter_tag(actor, action, current_filter, tag_slug) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, action, current_filter),
         {:ok, tag} <- fetch_tag_by_slug(tag_slug),
         :ok <- authorize(actor, :show, tag) do
      {:ok, tag}
    end
  end

  defp fetch_tag_by_slug(slug) do
    case Repo.get_by(Tag, slug: slug) do
      nil -> {:error, :not_found}
      %Tag{} = tag -> {:ok, tag}
    end
  end

  defp ensure_current_filter(%User{current_filter: %Filter{} = filter}), do: {:ok, filter}

  defp ensure_current_filter(%User{} = user) do
    filter = default_filter()

    case Users.set_current_filter(user, filter) do
      {:ok, _user} -> {:ok, filter}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp resolve_filter_for_switch(_actor, nil), do: {:ok, default_filter()}

  defp resolve_filter_for_switch(actor, id) do
    with {:ok, id} <- IntegerId.parse(id),
         %Filter{} = filter <- Repo.get(Filter, id) do
      case authorize(actor, :show, filter) do
        :ok -> {:ok, filter}
        {:error, :unauthorized} -> {:ok, default_filter()}
      end
    else
      _malformed_or_missing -> {:error, :not_found}
    end
  end

  defp persist_current_filter(nil, filter), do: {:ok, filter}

  defp persist_current_filter(%User{} = user, filter) do
    case Users.set_current_filter(user, filter) do
      {:ok, _user} -> {:ok, filter}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp recent_and_user_filter_choices(%User{} = user) do
    recent_filter_ids =
      [user.current_filter_id | user.recent_filter_ids]
      |> Enum.reject(&is_nil/1)
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
    |> Enum.sort_by(fn filter ->
      case Enum.find_index(recent_filter_ids, &(&1 == filter.id)) do
        nil -> length(recent_filter_ids)
        index -> index
      end
    end)
    |> Enum.group_by(
      fn
        %{recent: "t"} -> "Recent Filters"
        _user -> "Your Filters"
      end,
      fn %{id: id, name: name} -> [key: name, value: id] end
    )
    |> Enum.to_list()
    |> Enum.reverse()
  end

  # Parses the id, loads the filter, and authorizes `action` on it. A
  # non-castable or missing id is not-found for every actor; an existing but
  # forbidden filter is unauthorized.
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
  Returns the default filter.

  This canonical system row is required in every deployment.

  ## Examples

      iex> default_filter()
      %Filter{}

  """
  @spec default_filter() :: Filter.t()
  def default_filter do
    Filter
    |> where(system: true, name: "Default")
    |> Repo.one!()
  end

  @doc """
  Loads the effective current and forced filters for `actor`.

  Signed-in actors use their account associations. When no current filter has
  been selected, the canonical default is persisted first. Anonymous actors may
  select a visible filter through `cookie_filter_id`; malformed, missing, or
  forbidden cookie IDs fall back to the `default_filter/0`. Anonymous actors
  cannot have a forced filter.

  ## Examples

      iex> load_selected_filters(actor, "42")
      {:ok, %{current_filter: %Filter{}, forced_filter: nil}}

  """
  @spec load_selected_filters(Actor.t(), Loader.integer_id() | nil) ::
          {:ok, %{current_filter: Filter.t(), forced_filter: Filter.t() | nil}}
          | {:error, Ecto.Changeset.t()}
  def load_selected_filters(%Actor{user: nil} = actor, cookie_filter_id) do
    current_filter =
      case load_and_authorize_filter(actor, cookie_filter_id, :show) do
        {:ok, filter} -> filter
        {:error, _reason} -> default_filter()
      end

    {:ok, %{current_filter: current_filter, forced_filter: nil}}
  end

  def load_selected_filters(%Actor{user: %User{} = user}, _cookie_filter_id) do
    user = Repo.preload(user, [:current_filter, :forced_filter])

    with {:ok, current_filter} <- ensure_current_filter(user) do
      {:ok, %{current_filter: current_filter, forced_filter: user.forced_filter}}
    end
  end

  @doc """
  Returns the filters listed for `actor`: the viewer's own filters
  (empty for an anonymous visitor) and the system filters, each with `:user`
  preloaded. Authorizes the filter `:index` action before either query.

  ## Examples

      iex> index_filters(actor)
      {:ok, {[%Filter{}, ...], [%Filter{}, ...]}}

  """
  @spec index_filters(Actor.t()) ::
          {:ok, {[Filter.t()], [Filter.t()]}} | {:error, :unauthorized}
  def index_filters(%Actor{user: user} = actor) do
    with :ok <- authorize(actor, :index, Filter) do
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

      {:ok, {my_filters, system_filters}}
    end
  end

  @doc """
  Loads the filter named by `id` on behalf of `actor`, with `user` preloaded.

  Public and system filters are visible to everyone. Private filters are visible
  to their owner and staff with the corresponding `:show` grant.

  ## Examples

      iex> load_filter(actor, "1")
      {:ok, %Filter{}}

      iex> load_filter(actor, "not-a-number")
      {:error, :not_found}

      iex> load_filter(actor, unowned_private_filter_id)
      {:error, :unauthorized}

  """
  @spec load_filter(Actor.t(), Loader.integer_id()) ::
          {:ok, Filter.t()} | {:error, :not_found | :unauthorized}
  def load_filter(%Actor{} = actor, id) do
    load_and_authorize_filter(actor, id, :show, [:user])
  end

  @doc """
  Returns the page of system filters for `actor`.

  Authorizes `:index_system` before selecting filters flagged `system: true`,
  ordered by ascending id and paginated by `pagination`.

  ## Examples

      iex> system_filters(actor, pagination)
      {:ok, %Scrivener.Page{}}

  """
  @spec system_filters(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Filter.t())} | {:error, :unauthorized}
  def system_filters(%Actor{} = actor, pagination) do
    with :ok <- authorize(actor, :index_system, Filter) do
      {:ok,
       system_filters_query()
       |> order_by(asc: :id)
       |> Repo.paginate(pagination)}
    end
  end

  @doc """
  Returns the page of `actor`'s own filters after authorizing `:index_own`.

  Anonymous actors are unauthorized. Results are ordered by ascending id and
  paginated by `pagination`.

  ## Examples

      iex> user_filters(actor, pagination)
      {:ok, %Scrivener.Page{}}

  """
  @spec user_filters(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Filter.t())} | {:error, :unauthorized}
  def user_filters(%Actor{user: user} = actor, pagination) do
    with :ok <- authorize(actor, :index_own, Filter) do
      {:ok,
       user_filters_query(user)
       |> order_by(asc: :id)
       |> Repo.paginate(pagination)}
    end
  end

  @doc """
  Runs the filter search that `query_string` describes on behalf of `actor`.

  Compiles `query_string` against the filter search index and restricts results
  to filters the viewer may see. Anonymous visitors see public and system
  filters, members may also see their own private filters, and moderators/admins
  see all filters. Results are sorted by name then descending id, paginated by
  `pagination`, and loaded with `user` preloaded.

  ## Examples

      iex> search_filters(actor, "name:test", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_filters(actor, "name:(", pagination)
      {:error, "There was an error parsing your query."}

  """
  @spec search_filters(Actor.t(), String.t(), Search.pagination_params()) ::
          {:ok, Scrivener.Page.t(Filter.t())} | {:error, String.t()}
  def search_filters(%Actor{user: user} = actor, query_string, pagination) do
    with :ok <- authorize(actor, :search, Filter),
         {:ok, query} <- Query.compile(query_string, user: user) do
      filters =
        Filter
        |> Search.search_definition(
          %{
            query: %{
              bool: %{
                must: [query | visibility_filters(actor)]
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

  @doc """
  Assembles the filter page named by `id` for `actor`.

  Loads the filter with `user` preloaded, authorizes `:show`, and loads the
  filter's spoilered and hidden tags, each ordered by name.

  ## Examples

      iex> load_filter_page(actor, "1")
      {:ok, %FilterPage{}}

      iex> load_filter_page(actor, "999999999")
      {:error, :not_found}

      iex> load_filter_page(actor, unowned_private_filter_id)
      {:error, :unauthorized}

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

  @doc """
  Builds the changeset for a new filter on behalf of `actor`.

  Verifies write access, then authorizes `:new` (permitted for any signed-in
  user). When `based_on` names a filter the viewer may see, the new filter is
  prefilled from it as an unpersisted record; an unknown, malformed, forbidden,
  or omitted `based_on` yields a blank changeset.

  ## Examples

      iex> new_filter(actor, nil)
      {:ok, %Ecto.Changeset{}}

      iex> new_filter(actor, "1")
      {:ok, %Ecto.Changeset{}}

      iex> new_filter(actor, "999999999")
      {:ok, %Ecto.Changeset{data: %Filter{}}}

  """
  @spec new_filter(Actor.t(), Loader.integer_id() | nil) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized}
  def new_filter(%Actor{} = actor, based_on) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, Filter) do
      {:ok, change_filter(base_filter(actor, based_on))}
    end
  end

  @doc """
  Loads the filter named by `id` for editing on behalf of `actor`.

  Verifies write access, authorizes `:edit`, and assigns the spoilered and
  hidden tag lists onto the filter.

  ## Examples

      iex> load_filter_for_edit(actor, "1")
      {:ok, {%Filter{}, %Ecto.Changeset{}}}

      iex> load_filter_for_edit(actor, "999999999")
      {:error, :not_found}

      iex> load_filter_for_edit(actor, unowned_filter_id)
      {:error, :unauthorized}

  """
  @spec load_filter_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Filter.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def load_filter_for_edit(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, filter} <- load_and_authorize_filter(actor, id, :edit) do
      filter =
        filter
        |> TagList.assign_tag_list(:spoilered_tag_ids, :spoilered_tag_list)
        |> TagList.assign_tag_list(:hidden_tag_ids, :hidden_tag_list)

      {:ok, {filter, change_filter(filter)}}
    end
  end

  @doc """
  Switches `actor`'s current filter to the one named by `id`.

  Verifies write access and authorizes `:switch` before loading. `nil` explicitly
  selects the canonical default filter. A visible filter is selected directly.
  A private filter the actor may not see also resolves to the default. Malformed
  and missing non-nil IDs are not-found.

  For a signed-in actor, the selection is persisted to their account and added
  to recent filters. Anonymous actors must persist the filter through the returned
  Filter struct. Any applicable forced filter is independent and remains unchanged.

  ## Examples

      iex> switch_current_filter(actor, "1")
      {:ok, %Filter{}}

      iex> switch_current_filter(actor, "999999999")
      {:error, :not_found}

      iex> switch_current_filter(actor, nil)
      {:ok, %Filter{name: "Default"}}

  """
  @spec switch_current_filter(Actor.t(), Loader.integer_id() | nil) ::
          {:ok, Filter.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def switch_current_filter(%Actor{user: user} = actor, id) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :switch, Filter),
         {:ok, filter} <- resolve_filter_for_switch(actor, id) do
      persist_current_filter(user, filter)
    end
  end

  @doc """
  Creates a filter owned by `actor`.

  Verifies write access, authorizes `:create`, then inserts the filter and queues
  it for reindexing.

  ## Examples

      iex> create_filter(actor, %{field: value})
      {:ok, %Filter{}}

      iex> create_filter(actor, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

      iex> create_filter(anonymous_actor, %{field: value})
      {:error, :unauthorized}

  """
  @spec create_filter(Actor.t(), map()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :unauthorized}
  def create_filter(%Actor{user: user} = actor, attrs \\ %{}) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Filter) do
      create_loaded_filter(user, attrs)
    end
  end

  @doc """
  Updates the filter named by `id`, on behalf of `actor`.

  Verifies write access, loads the filter, authorizes `:update`, then applies
  `attrs`.

  ## Examples

      iex> update_filter(actor, "1", %{"name" => "Renamed"})
      {:ok, %Filter{}}

      iex> update_filter(actor, "1", invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_filter(actor, "999999999", filter_params)
      {:error, :not_found}

      iex> update_filter(actor, unowned_filter_id, filter_params)
      {:error, :unauthorized}

  """
  @spec update_filter(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def update_filter(%Actor{} = actor, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, filter} <- load_and_authorize_filter(actor, id, :update) do
      persist_filter_update(filter, attrs)
    end
  end

  @doc """
  Makes the filter named by `id` public, on behalf of `actor`.

  Verifies write access, loads the filter, authorizes the distinct `:publish`
  action, then makes it public. Publishing an already-public filter is
  idempotent.

  ## Examples

      iex> make_filter_public(actor, "1")
      {:ok, %Filter{}}

      iex> make_filter_public(actor, unowned_filter_id)
      {:error, :unauthorized}

      iex> make_filter_public(actor, "999999999")
      {:error, :not_found}

  """
  @spec make_filter_public(Actor.t(), Loader.integer_id()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def make_filter_public(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, filter} <- load_and_authorize_filter(actor, id, :publish) do
      persist_filter_publication(filter)
    end
  end

  @doc """
  Deletes the filter named by `id`, on behalf of `actor`.

  Verifies write access, loads the filter, authorizes `:delete`, then deletes it.
  A filter referenced as a user's current or forced filter returns a rejected
  changeset and cannot be deleted.

  ## Examples

      iex> delete_filter(actor, "1")
      {:ok, %Filter{}}

      iex> delete_filter(actor, "999999999")
      {:error, :not_found}

      iex> delete_filter(actor, unowned_filter_id)
      {:error, :unauthorized}

  """
  @spec delete_filter(Actor.t(), Loader.integer_id()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def delete_filter(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, filter} <- load_and_authorize_filter(actor, id, :delete) do
      persist_filter_deletion(filter)
    end
  end

  @doc """
  Returns `actor`'s grouped recent and personal filter choices.

  Authorizes `:index_own` before querying. Anonymous actors are unauthorized.

  ## Examples

      iex> recent_and_user_filters(actor)
      {:ok,
       [
         {"Recent Filters", [[key: "Filter 1", value: 1], ...]},
         {"Your Filters", [[key: "Filter 2", value: 2], ...]}
       ]}

  """
  @spec recent_and_user_filters(Actor.t()) ::
          {:ok, [{String.t(), [[key: String.t(), value: integer()]]}]}
          | {:error, :unauthorized}
  def recent_and_user_filters(%Actor{user: user} = actor) do
    with :ok <- authorize(actor, :index_own, Filter) do
      {:ok, recent_and_user_filter_choices(user)}
    end
  end

  @doc """
  Adds the tag named by `tag_slug` to `current_filter`'s hidden tags on behalf
  of `actor`.

  Rejects a banned actor or one without a fingerprint, authorizes `:hide_tag`
  on the loaded current filter, safely loads the tag, and authorizes the tag for
  `:show`. System filters and filters owned by someone else cannot be changed.

  ## Examples

      iex> hide_tag(actor, filter, tag_slug)
      {:ok, %Filter{}}

      iex> hide_tag(banned_actor, filter, tag_slug)
      {:error, :ban}

      iex> hide_tag(actor, filter, unknown_tag_slug)
      {:error, :not_found}

      iex> hide_tag(actor, unowned_filter, tag_slug)
      {:error, :unauthorized}

  """
  @spec hide_tag(Actor.t(), Filter.t(), String.t()) ::
          {:ok, Filter.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def hide_tag(%Actor{} = actor, %Filter{} = current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, :hide_tag, current_filter, tag_slug) do
      persist_hidden_tag(current_filter, tag)
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
  def unhide_tag(%Actor{} = actor, %Filter{} = current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, :unhide_tag, current_filter, tag_slug) do
      persist_unhidden_tag(current_filter, tag)
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
  def spoiler_tag(%Actor{} = actor, %Filter{} = current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, :spoiler_tag, current_filter, tag_slug) do
      persist_spoilered_tag(current_filter, tag)
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
  def unspoiler_tag(%Actor{} = actor, %Filter{} = current_filter, tag_slug) do
    with {:ok, tag} <- authorize_filter_tag(actor, :unspoiler_tag, current_filter, tag_slug) do
      persist_unspoilered_tag(current_filter, tag)
    end
  end

  @doc """
  Updates filter indexes when a user's name changes.

  Issues asynchronous update-by-query requests for every physical filter index.

  ## Examples

      iex> user_name_reindex("old_name", "new_name")
      [update_result, ...]

  """
  @spec user_name_reindex(String.t(), String.t()) :: [term()]
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
  @spec reindex_filter(Filter.t()) :: Filter.t()
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
  @spec indexing_preloads() :: list()
  def indexing_preloads do
    [:user]
  end

  @doc """
  Performs a search reindex operation on filters matching the given criteria.

  `column` is supplied by the trusted worker registry, not request input.

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      :ok

  """
  @spec perform_reindex(atom(), [term()]) :: :ok
  def perform_reindex(column, condition) do
    Filter
    |> preload(^indexing_preloads())
    |> where([f], field(f, ^column) in ^condition)
    |> Search.reindex(Filter)
  end
end
