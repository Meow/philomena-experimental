defmodule Philomena.Commissions do
  @moduledoc """
  The Commissions context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [verify_write_access: 1, verify_not_banned: 1]

  alias Philomena.IntegerId
  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Users.User
  alias Philomena.Commissions.Commission
  alias Philomena.Commissions.Item
  alias Philomena.Commissions.QueryBuilder
  alias Philomena.Commissions.SearchQuery
  alias Philomena.Reports

  @profile_preloads [
    :verified_links,
    commission: [
      sheet_image: [:sources, tags: :aliases],
      user: [awards: :badge],
      items: [example_image: [:sources, tags: :aliases]]
    ]
  ]

  # Creates a commission. Visible for testing.
  @doc false
  def create_commission(user, attrs \\ %{}) do
    Ecto.build_assoc(user, :commission)
    |> Commission.changeset(attrs)
    |> Repo.insert()
  end

  # Updates a commission.
  defp update_commission(%Commission{} = commission, attrs) do
    commission
    |> Commission.changeset(attrs)
    |> Repo.update()
  end

  # Deletes a commission.
  defp delete_commission(%Commission{} = commission, closing_user, _unused) do
    Multi.new()
    |> Multi.update_all(
      :reports,
      Reports.close_report_query(closing_user, commission_id: commission.id),
      []
    )
    |> Multi.delete(:commission, commission)
    |> Repo.transaction()
    |> case do
      {:ok, %{commission: commission, reports: {_count, reports}}} ->
        Reports.reindex_reports(reports)

        {:ok, commission}

      error ->
        error
    end
  end

  # Returns an `%Ecto.Changeset{}` for tracking commission changes.
  # Visible for testing.
  @doc false
  def change_commission(%Commission{} = commission) do
    Commission.changeset(commission, %{})
  end

  @doc """
  Loads the commission of the user named by the profile `slug`.

  ## Examples

      iex> load_commission_for_show(user.slug)
      {:ok, {%User{}, %Commission{}}}

      iex> load_commission_for_show(user_without_commission.slug)
      {:error, :not_found}

      iex> load_commission_for_show(invalid_slug)
      {:error, :not_found}

  """
  @spec load_commission_for_show(String.t()) ::
          {:ok, {User.t(), Commission.t()}} | {:error, :not_found}
  def load_commission_for_show(slug) do
    case load_profile_user(slug) do
      %User{commission: %Commission{} = commission} = user -> {:ok, {user, commission}}
      _other -> {:error, :not_found}
    end
  end

  @doc """
  Loads the user named by the profile `slug` for creating a commission, on
  behalf of `actor`.

  ## Examples

      iex> load_commission_for_new(user, user.slug)
      {:ok, %User{}}

      iex> load_commission_for_new(admin, user.slug)
      {:ok, %User{}}

      iex> load_commission_for_new(admin, invalid_slug)
      {:error, :not_found}

      iex> load_commission_for_new(banned_user, banned_user.slug)
      {:error, :ban}

      iex> load_commission_for_new(user, other_user.slug)
      {:error, :unauthorized}

      iex> load_commission_for_new(user_without_links, user_without_links.slug)
      {:error, :no_verified_links}

  """
  @spec load_commission_for_new(Actor.t(), String.t()) ::
          {:ok, User.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def load_commission_for_new(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor) do
      authorize_new_commission(actor, slug)
    end
  end

  @doc """
  Creates a commission for the user named by the profile `slug`, on behalf of
  `actor`, from `attrs`.

  ## Examples

      iex> create_commission(user, user.slug, commission_params)
      {:ok, {%User{}, %Commission{}}}

      iex> create_commission(user, user.slug, invalid_params)
      {:error, {%User{}, %Ecto.Changeset{}}}

      iex> create_commission(admin, invalid_slug, commission_params)
      {:error, :not_found}

      iex> create_commission(banned_user, banned_user.slug, commission_params)
      {:error, :ban}

      iex> create_commission(user, other_user.slug, commission_params)
      {:error, :unauthorized}

      iex> create_commission(user_without_links, user_without_links.slug, commission_params)
      {:error, :no_verified_links}

  """
  @spec create_commission(Actor.t(), String.t(), map()) ::
          {:ok, {User.t(), Commission.t()}}
          | {:error, {User.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def create_commission(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- authorize_new_commission(actor, slug) do
      case create_commission(user, attrs) do
        {:ok, commission} -> {:ok, {user, commission}}
        {:error, changeset} -> {:error, {user, changeset}}
      end
    end
  end

  @doc """
  Loads the commission of the user named by the profile `slug` for editing, on
  behalf of `actor`.

  ## Examples

      iex> load_commission_for_edit(user, user.slug)
      {:ok, {%User{}, %Commission{}, %Ecto.Changeset{}}}

      iex> load_commission_for_edit(admin, invalid_slug)
      {:error, :not_found}

      iex> load_commission_for_edit(banned_user, banned_user.slug)
      {:error, :ban}

      iex> load_commission_for_edit(user, other_user.slug)
      {:error, :unauthorized}

      iex> load_commission_for_edit(user_without_links, user_without_links.slug)
      {:error, :no_verified_links}

  """
  @spec load_commission_for_edit(Actor.t(), String.t()) ::
          {:ok, {User.t(), Commission.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def load_commission_for_edit(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, {user, commission}} <- authorize_existing_commission(actor, slug) do
      {:ok, {user, commission, change_commission(commission)}}
    end
  end

  @doc """
  Updates the commission of the user named by the profile `slug`, on behalf of
  `actor`, from `attrs`.

  ## Examples

      iex> update_commission(user, user.slug, commission_params)
      {:ok, {%User{}, %Commission{}}}

      iex> update_commission(user, user.slug, invalid_params)
      {:error, {%User{}, %Ecto.Changeset{}}}

      iex> update_commission(admin, invalid_slug, commission_params)
      {:error, :not_found}

      iex> update_commission(banned_user, banned_user.slug, commission_params)
      {:error, :ban}

      iex> update_commission(user, other_user.slug, commission_params)
      {:error, :unauthorized}

      iex> update_commission(user_without_links, user_without_links.slug, commission_params)
      {:error, :no_verified_links}

  """
  @spec update_commission(Actor.t(), String.t(), map()) ::
          {:ok, {User.t(), Commission.t()}}
          | {:error, {User.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def update_commission(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- authorize_existing_commission(actor, slug) do
      case update_commission(commission, attrs) do
        {:ok, commission} -> {:ok, {user, commission}}
        {:error, changeset} -> {:error, {user, changeset}}
      end
    end
  end

  @doc """
  Deletes the commission of the user named by the profile `slug`, on behalf of
  `actor`.

  ## Examples

      iex> delete_commission(user, user.slug)
      {:ok, %Commission{}}

      iex> delete_commission(admin, invalid_slug)
      {:error, :not_found}

      iex> delete_commission(banned_user, banned_user.slug)
      {:error, :ban}

      iex> delete_commission(user, other_user.slug)
      {:error, :unauthorized}

      iex> delete_commission(user_without_links, user_without_links.slug)
      {:error, :no_verified_links}

  """
  @spec delete_commission(Actor.t(), String.t()) ::
          {:ok, Commission.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def delete_commission(%Actor{user: user} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- authorize_existing_commission(actor, slug) do
      delete_commission(commission, user, nil)
    end
  end

  defp load_profile_user(slug) do
    User
    |> where(slug: ^slug)
    |> preload(^@profile_preloads)
    |> Repo.one()
  end

  # Gates commission creation: the profile must exist and have no commission, the
  # actor must be the profile owner or staff, and the profile must hold a
  # verified artist link.
  defp authorize_new_commission(actor, slug) do
    with %User{} = user <- load_profile_user(slug),
         :ok <- ensure_no_commission(user),
         :ok <- ensure_correct_user(actor.user, user),
         :ok <- ensure_links_verified(user) do
      {:ok, user}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  # Gates access to an existing commission: the profile must exist and have a
  # commission, the actor must be the profile owner or staff, and the profile
  # must hold a verified artist link.
  defp authorize_existing_commission(actor, slug) do
    with %User{} = user <- load_profile_user(slug),
         {:ok, commission} <- ensure_commission(user),
         :ok <- ensure_correct_user(actor.user, user),
         :ok <- ensure_links_verified(user) do
      {:ok, {user, commission}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp ensure_no_commission(%User{commission: nil}), do: :ok
  defp ensure_no_commission(%User{}), do: {:error, :unauthorized}

  defp ensure_commission(%User{commission: %Commission{} = commission}), do: {:ok, commission}
  defp ensure_commission(%User{}), do: {:error, :not_found}

  defp ensure_correct_user(%{id: id}, %User{id: id}), do: :ok
  defp ensure_correct_user(%{role: role}, _user) when role in ["admin", "moderator"], do: :ok
  defp ensure_correct_user(_current, _user), do: {:error, :unauthorized}

  defp ensure_links_verified(user) do
    if Enum.any?(user.verified_links) do
      :ok
    else
      {:error, :no_verified_links}
    end
  end

  # Returns an `%Ecto.Changeset{}` for tracking search query changes.
  defp change_search_query(%SearchQuery{} = search_query) do
    SearchQuery.changeset(search_query, %{})
  end

  @doc """
  Generates a search query based on the given parameters.

  ## Parameters

    * params - Map of optional search parameters:
      * item_type - Filter by item type
      * category - Filter by category
      * keywords - Search in information and will_create fields
      * price_min - Minimum base price
      * price_max - Maximum base price

  ## Examples

      iex> commission_search_query(params)
      {:ok, #Ecto.Query<...>}

      iex> commission_search_query(invalid_params)
      {:error, %Ecto.Changeset{}}

  """
  def commission_search_query(params \\ %{}) do
    QueryBuilder.search_commissions(params)
  end

  @doc """
  Runs the commission directory search for the given `params` and `pagination`.

  Returns `{commissions, changeset}`: a `m:Scrivener.Page` of matching
  commissions with a fresh search changeset on success, or an empty page with the
  invalid search changeset when the parameters are rejected. The empty page keeps
  callers that paginate the results from receiving a bare list.

  ## Examples

      iex> search_directory(params, pagination)
      {%Scrivener.Page{}, %Ecto.Changeset{}}

      iex> search_directory(invalid_params, pagination)
      {%Scrivener.Page{}, %Ecto.Changeset{}}

  """
  @spec search_directory(map(), Repo.pagination_params()) ::
          {Scrivener.Page.t(Commission.t()), Ecto.Changeset.t()}
  def search_directory(params, pagination) do
    case commission_search_query(params) do
      {:ok, commissions} ->
        {Repo.paginate(commissions, pagination), change_search_query(%SearchQuery{})}

      {:error, changeset} ->
        {empty_page(pagination), changeset}
    end
  end

  defp empty_page(pagination) do
    %Scrivener.Page{
      entries: [],
      page_number: Keyword.get(pagination, :page, 1),
      page_size: Keyword.get(pagination, :page_size, 25),
      total_entries: 0,
      total_pages: 1
    }
  end

  @doc """
  Preloads the commission of `user` (the current viewer, possibly `nil`).
  """
  @spec preload_commission(User.t() | nil) :: User.t() | nil
  def preload_commission(nil), do: nil
  def preload_commission(%User{} = user), do: Repo.preload(user, :commission)

  # Creates an item. Visible for testing.
  @doc false
  def create_item(commission, attrs \\ %{}) do
    changeset =
      Ecto.build_assoc(commission, :items)
      |> Item.changeset(attrs)

    update =
      Commission
      |> where(id: ^commission.id)
      |> update(inc: [commission_items_count: 1])

    Multi.new()
    |> Multi.insert(:item, changeset)
    |> Multi.update_all(:commission, update, [])
    |> Repo.transaction()
    |> case do
      {:error, :item, changeset, _} ->
        {:error, changeset}

      result ->
        result
    end
  end

  # Updates an item.
  defp update_item(%Item{} = item, attrs) do
    item
    |> Item.changeset(attrs)
    |> Repo.update()
  end

  # Deletes an item.
  defp delete_item(%Item{} = item) do
    update =
      Commission
      |> where(id: ^item.commission_id)
      |> update(inc: [commission_items_count: -1])

    Multi.new()
    |> Multi.delete(:item, item)
    |> Multi.update_all(:commission, update, [])
    |> Repo.transaction()
  end

  # Returns an `%Ecto.Changeset{}` for tracking item changes.
  defp change_item(%Item{} = item) do
    Item.changeset(item, %{})
  end

  @doc """
  Loads the commission of the user named by the profile `slug` for adding an
  item, on behalf of `actor`.

  Items are strictly owner-only, so an actor who is not the profile owner is
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_item_for_new(user, user.slug)
      {:ok, {%User{}, %Commission{}, %Ecto.Changeset{}}}

      iex> load_item_for_new(admin, other_user.slug)
      {:error, :unauthorized}

      iex> load_item_for_new(banned_user, banned_user.slug)
      {:error, :ban}

      iex> load_item_for_new(user_without_commission, user_without_commission.slug)
      {:error, :not_found}

  """
  @spec load_item_for_new(Actor.t(), String.t()) ::
          {:ok, {User.t(), Commission.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_item_for_new(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, {user, commission}} <- authorize_item(actor, slug) do
      {:ok, {user, commission, change_item(%Item{})}}
    end
  end

  @doc """
  Adds an item to the commission of the user named by the profile `slug`, on
  behalf of `actor`, from `attrs`.

  Items are strictly owner-only, so an actor who is not the profile owner is
  `{:error, :unauthorized}`.

  ## Examples

      iex> create_item(user, user.slug, item_params)
      {:ok, %User{}}

      iex> create_item(user, user.slug, invalid_params)
      {:error, {%User{}, %Commission{}, %Ecto.Changeset{}}}

      iex> create_item(admin, other_user.slug, item_params)
      {:error, :unauthorized}

      iex> create_item(banned_user, banned_user.slug, item_params)
      {:error, :ban}

      iex> create_item(user_without_commission, user_without_commission.slug, item_params)
      {:error, :not_found}

  """
  @spec create_item(Actor.t(), String.t(), map()) ::
          {:ok, User.t()}
          | {:error, {User.t(), Commission.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def create_item(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- authorize_item(actor, slug) do
      case create_item(commission, attrs) do
        {:ok, _multi} -> {:ok, user}
        {:error, changeset} -> {:error, {user, commission, changeset}}
      end
    end
  end

  @doc """
  Loads the item named by `id` under the commission of the user named by the
  profile `slug` for editing, on behalf of `actor`.

  Items are strictly owner-only, so an actor who is not the profile owner is
  `{:error, :unauthorized}`.

  ## Examples

      iex> load_item_for_edit(user, user.slug, item_id)
      {:ok, {%User{}, %Commission{}, %Item{}, %Ecto.Changeset{}}}

      iex> load_item_for_edit(admin, other_user.slug, item_id)
      {:error, :unauthorized}

      iex> load_item_for_edit(banned_user, banned_user.slug, item_id)
      {:error, :ban}

      iex> load_item_for_edit(user_without_commission, user_without_commission.slug, invalid_id)
      {:error, :not_found}

  """
  @spec load_item_for_edit(Actor.t(), String.t(), IntegerId.integer_id()) ::
          {:ok, {User.t(), Commission.t(), Item.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_item_for_edit(%Actor{} = actor, slug, id) do
    with :ok <- verify_not_banned(actor),
         {:ok, {user, commission}} <- authorize_item(actor, slug) do
      # TODO: fix raise when invalid item is passed here
      item = fetch_item!(commission, id)
      {:ok, {user, commission, item, change_item(item)}}
    end
  end

  @doc """
  Updates the item named by `id` under the commission of the user named by the
  profile `slug`, on behalf of `actor`, from `attrs`.

  Items are strictly owner-only, so an actor who is not the profile owner is
  `{:error, :unauthorized}`.

  ## Examples

      iex> update_item(user, user.slug, item_id, item_params)
      {:ok, %User{}}

      iex> update_item(user, user.slug, item_id, invalid_params)
      {:error, {%User{}, %Commission{}, %Item{}, %Ecto.Changeset{}}}

      iex> update_item(admin, other_user.slug, item_id, item_params)
      {:error, :unauthorized}

      iex> update_item(banned_user, banned_user.slug, item_id, item_params)
      {:error, :ban}

      iex> update_item(user_without_commission, user_without_commission.slug, invalid_id, item_params)
      {:error, :not_found}

  """
  @spec update_item(Actor.t(), String.t(), IntegerId.integer_id(), map()) ::
          {:ok, User.t()}
          | {:error, {User.t(), Commission.t(), Item.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def update_item(%Actor{} = actor, slug, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- authorize_item(actor, slug) do
      item = fetch_item!(commission, id)

      case update_item(item, attrs) do
        {:ok, _item} -> {:ok, user}
        {:error, changeset} -> {:error, {user, commission, item, changeset}}
      end
    end
  end

  @doc """
  Deletes the item named by `id` under the commission of the user named by the
  profile `slug`, on behalf of `actor`.

  Items are strictly owner-only, so an actor who is not the profile owner is
  `{:error, :unauthorized}`.

  ## Examples

      iex> delete_item(user, user.slug, item_id)
      {:ok, %User{}}

      iex> delete_item(admin, other_user.slug, item_id)
      {:error, :unauthorized}

      iex> delete_item(banned_user, banned_user.slug, item_id)
      {:error, :ban}

      iex> delete_item(user_without_commission, user_without_commission.slug, invalid_id)
      {:error, :not_found}

  """
  @spec delete_item(Actor.t(), String.t(), IntegerId.integer_id()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def delete_item(%Actor{} = actor, slug, id) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- authorize_item(actor, slug) do
      item = fetch_item!(commission, id)
      {:ok, _multi} = delete_item(item)
      {:ok, user}
    end
  end

  # Gates item management: the profile must exist and have a commission, and the
  # actor must be the profile owner. Unlike commission management, item
  # management has no staff bypass.
  defp authorize_item(actor, slug) do
    with %User{} = user <- load_profile_user(slug),
         {:ok, commission} <- ensure_commission(user),
         :ok <- ensure_item_owner(actor.user, user) do
      {:ok, {user, commission}}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp ensure_item_owner(%{id: id}, %User{id: id}), do: :ok
  defp ensure_item_owner(_current, _user), do: {:error, :unauthorized}

  # Loads an item scoped to its commission, raising `Ecto.NoResultsError`
  # when the id names no item of this commission.
  defp fetch_item!(commission, id) do
    Repo.get_by!(Item, commission_id: commission.id, id: id)
  end
end
