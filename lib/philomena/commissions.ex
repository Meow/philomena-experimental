defmodule Philomena.Commissions do
  @moduledoc """
  The Commissions context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [verify_write_access: 1, verify_not_banned: 1]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Users.User
  alias Philomena.Commissions.Commission
  alias Philomena.Commissions.Item
  alias Philomena.Commissions.QueryBuilder
  alias Philomena.Commissions.SearchQuery

  @profile_preloads [
    :verified_links,
    commission: [
      sheet_image: [:sources, tags: :aliases],
      user: [awards: :badge],
      items: [example_image: [:sources, tags: :aliases]]
    ]
  ]

  @doc """
  Gets a single commission.

  Raises `Ecto.NoResultsError` if the Commission does not exist.

  ## Examples

      iex> get_commission!(123)
      %Commission{}

      iex> get_commission!(456)
      ** (Ecto.NoResultsError)

  """
  def get_commission!(id), do: Repo.get!(Commission, id)

  @doc """
  Creates a commission.

  ## Examples

      iex> create_commission(%{field: value})
      {:ok, %Commission{}}

      iex> create_commission(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_commission(user, attrs \\ %{}) do
    Ecto.build_assoc(user, :commission)
    |> Commission.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a commission.

  ## Examples

      iex> update_commission(commission, %{field: new_value})
      {:ok, %Commission{}}

      iex> update_commission(commission, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_commission(%Commission{} = commission, attrs) do
    commission
    |> Commission.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Commission.

  ## Examples

      iex> delete_commission(commission)
      {:ok, %Commission{}}

      iex> delete_commission(commission)
      {:error, %Ecto.Changeset{}}

  """
  def delete_commission(%Commission{} = commission) do
    Repo.delete(commission)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking commission changes.

  ## Examples

      iex> change_commission(commission)
      %Ecto.Changeset{source: %Commission{}}

  """
  def change_commission(%Commission{} = commission) do
    Commission.changeset(commission, %{})
  end

  @doc """
  Loads the commission of the user named by the profile `slug` for display.

  The commission sheet is public. An unknown slug, or a user without a
  commission, is `{:error, :not_found}`.

  Returns `{:ok, {user, commission}}` with the commission's items, sheet image,
  and owner preloaded for rendering.
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
  Loads the user named by the profile `slug` for the new commission form, on
  behalf of `actor`.

  A banned actor is rejected first with `{:error, :ban}`. An unknown slug is
  `{:error, :not_found}`. Creating a commission requires the profile to have no
  existing commission, the actor to be the profile owner or staff, and the
  profile to hold a verified artist link; the respective failures are
  `{:error, :unauthorized}`, `{:error, :unauthorized}`, and
  `{:error, :no_verified_links}`.

  Returns `{:ok, user}`.
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
  `actor`, from the controller-shaped `attrs`.

  The actor's write access is verified first (`{:error, :ban}` /
  `{:error, :unauthorized}`); then the same gating as
  `load_commission_for_new/2` applies. On success the commission is created for
  the profile user.

  Returns `{:ok, {user, commission}}` on success, or
  `{:error, {user, changeset}}` when the insert is rejected.
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

  A banned actor is rejected first with `{:error, :ban}`. A missing commission
  (or unknown slug) is `{:error, :not_found}`. Editing requires the actor to be
  the profile owner or staff (`{:error, :unauthorized}`) and the profile to hold
  a verified artist link (`{:error, :no_verified_links}`).

  Returns `{:ok, {user, commission, changeset}}`.
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
  `actor`, from the controller-shaped `attrs`.

  The actor's write access is verified first (`{:error, :ban}` /
  `{:error, :unauthorized}`); then the same gating as
  `load_commission_for_edit/2` applies.

  Returns `{:ok, {user, commission}}` on success, or
  `{:error, {user, changeset}}` when the update is rejected.
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

  The actor's write access is verified first (`{:error, :ban}` /
  `{:error, :unauthorized}`); then the same gating as
  `load_commission_for_edit/2` applies.

  Returns `{:ok, commission}`.
  """
  @spec delete_commission(Actor.t(), String.t()) ::
          {:ok, Commission.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def delete_commission(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- authorize_existing_commission(actor, slug) do
      delete_commission(commission)
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

  @doc """
  Searches commissions based on the given parameters.

  ## Parameters

    * params - Map of optional search parameters:
      * item_type - Filter by item type
      * category - Filter by category
      * keywords - Search in information and will_create fields
      * price_min - Minimum base price
      * price_max - Maximum base price

  Returns `{:ok, query}` with a queryable that can be used with Repo.paginate/2,
  or `{:error, changeset}` if the provided parameters are invalid.
  """
  def execute_search_query(params \\ %{}) do
    QueryBuilder.search_commissions(params)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking search query changes.

  ## Examples

      iex> change_search_query(search_query)
      %Ecto.Changeset{source: %SearchQuery{}}

  """
  def change_search_query(%SearchQuery{} = search_query) do
    SearchQuery.changeset(search_query, %{})
  end

  @doc """
  Gets a single item.

  Raises `Ecto.NoResultsError` if the Item does not exist.

  ## Examples

      iex> get_item!(123)
      %Item{}

      iex> get_item!(456)
      ** (Ecto.NoResultsError)

  """
  def get_item!(id), do: Repo.get!(Item, id)

  @doc """
  Creates a item.

  ## Examples

      iex> create_item(%{field: value})
      {:ok, %Item{}}

      iex> create_item(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
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

  @doc """
  Updates a item.

  ## Examples

      iex> update_item(item, %{field: new_value})
      {:ok, %Item{}}

      iex> update_item(item, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_item(%Item{} = item, attrs) do
    item
    |> Item.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Item.

  ## Examples

      iex> delete_item(item)
      {:ok, %Item{}}

      iex> delete_item(item)
      {:error, %Ecto.Changeset{}}

  """
  def delete_item(%Item{} = item) do
    update =
      Commission
      |> where(id: ^item.commission_id)
      |> update(inc: [commission_items_count: -1])

    Multi.new()
    |> Multi.delete(:item, item)
    |> Multi.update_all(:commission, update, [])
    |> Repo.transaction()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking item changes.

  ## Examples

      iex> change_item(item)
      %Ecto.Changeset{source: %Item{}}

  """
  def change_item(%Item{} = item) do
    Item.changeset(item, %{})
  end

  @doc """
  Loads the commission of the user named by the profile `slug` for adding an
  item, on behalf of `actor`.

  A banned actor is rejected first with `{:error, :ban}`. A missing commission
  (or unknown slug) is `{:error, :not_found}`. Items are strictly owner-only, so
  an actor who is not the profile owner is `{:error, :unauthorized}`.

  Returns `{:ok, {user, commission, changeset}}`.
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
  behalf of `actor`, from the controller-shaped `attrs`.

  The actor's write access is verified first (`{:error, :ban}` /
  `{:error, :unauthorized}`); then the same gating as `load_item_for_new/2`
  applies.

  Returns `{:ok, user}` on success, or `{:error, {user, commission, changeset}}`
  when the insert is rejected.
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

  A banned actor is rejected first with `{:error, :ban}`. A missing commission
  (or unknown slug) is `{:error, :not_found}`, and a non-owner is
  `{:error, :unauthorized}`. An item id that does not belong to this commission
  raises `Ecto.NoResultsError` (a 404).

  Returns `{:ok, {user, commission, item, changeset}}`.
  """
  @spec load_item_for_edit(Actor.t(), String.t(), String.t()) ::
          {:ok, {User.t(), Commission.t(), Item.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_item_for_edit(%Actor{} = actor, slug, id) do
    with :ok <- verify_not_banned(actor),
         {:ok, {user, commission}} <- authorize_item(actor, slug) do
      item = fetch_item!(commission, id)
      {:ok, {user, commission, item, change_item(item)}}
    end
  end

  @doc """
  Updates the item named by `id` under the commission of the user named by the
  profile `slug`, on behalf of `actor`, from the controller-shaped `attrs`.

  The actor's write access is verified first (`{:error, :ban}` /
  `{:error, :unauthorized}`); then the same gating as `load_item_for_edit/3`
  applies, including the raising item lookup.

  Returns `{:ok, user}` on success, or
  `{:error, {user, commission, item, changeset}}` when the update is rejected.
  """
  @spec update_item(Actor.t(), String.t(), String.t(), map()) ::
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

  The actor's write access is verified first (`{:error, :ban}` /
  `{:error, :unauthorized}`); then the same gating as `load_item_for_edit/3`
  applies, including the raising item lookup.

  Returns `{:ok, user}`.
  """
  @spec delete_item(Actor.t(), String.t(), String.t()) ::
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
  # actor must be the profile owner. Unlike commission management, item routes
  # have no staff bypass.
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

  # Loads an item scoped to its commission, raising `Ecto.NoResultsError` (a 404)
  # when the id names no item of this commission.
  defp fetch_item!(commission, id) do
    Repo.get_by!(Item, commission_id: commission.id, id: id)
  end
end
