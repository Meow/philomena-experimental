defmodule Philomena.Commissions do
  @moduledoc """
  Commission directory, profile listings, and listing item management.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Multi
  alias Philomena.Attribution.Actor
  alias Philomena.Commissions.Commission
  alias Philomena.Commissions.CommissionForm
  alias Philomena.Commissions.CommissionPage
  alias Philomena.Commissions.Directory
  alias Philomena.Commissions.Item
  alias Philomena.Commissions.QueryBuilder
  alias Philomena.Commissions.SearchQuery
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.Repo
  alias Philomena.Reports
  alias Philomena.Users
  alias Philomena.Users.User

  @profile_preloads [:verified_links]
  @commission_preloads [
    sheet_image: [:sources, tags: :aliases],
    user: [awards: :badge],
    items: [example_image: [:sources, tags: :aliases]]
  ]

  defp load_profile(actor, slug) do
    with {:ok, user} <- Users.load_profile(actor, slug) do
      {:ok, Repo.preload(user, @profile_preloads)}
    end
  end

  defp commission_for_user(%User{id: user_id}) do
    Commission
    |> where(user_id: ^user_id)
    |> preload(^@commission_preloads)
    |> Loader.one()
  end

  defp commission_page(%User{} = user, %Commission{} = commission) do
    commission = Repo.preload(commission, @commission_preloads)

    %CommissionPage{user: user, commission: commission}
  end

  defp load_commission(actor, slug, action) do
    with {:ok, user} <- load_profile(actor, slug),
         {:ok, commission} <- commission_for_user(user),
         :ok <- authorize(actor, action, commission) do
      {:ok, {user, commission}}
    end
  end

  defp load_manageable_commission(actor, slug, action) do
    with {:ok, {user, commission}} <- load_commission(actor, slug, action),
         :ok <- ensure_links_verified(user) do
      {:ok, {user, commission}}
    end
  end

  defp load_new_commission(actor, slug, action) do
    with {:ok, user} <- load_profile(actor, slug),
         commission = Ecto.build_assoc(user, :commission),
         :ok <- authorize(actor, action, commission),
         :ok <- ensure_no_commission(user),
         :ok <- ensure_links_verified(user) do
      {:ok, {user, commission}}
    end
  end

  defp ensure_no_commission(%User{id: user_id}) do
    if Repo.exists?(where(Commission, user_id: ^user_id)) do
      {:error, :unauthorized}
    else
      :ok
    end
  end

  defp ensure_links_verified(%User{verified_links: links}) do
    if Enum.any?(links) do
      :ok
    else
      {:error, :no_verified_links}
    end
  end

  defp commission_form(user, commission, changeset \\ nil) do
    %CommissionForm{
      user: user,
      commission: commission,
      changeset: changeset || Commission.changeset(commission, %{})
    }
  end

  defp item_for_commission(%Commission{} = commission, id) do
    Item
    |> where(commission_id: ^commission.id)
    |> preload(commission: :user)
    |> Loader.fetch(id)
  end

  defp new_item(%Commission{} = commission) do
    commission
    |> Ecto.build_assoc(:items)
    |> Map.put(:commission, commission)
  end

  defp search_directory(params, pagination) do
    case QueryBuilder.search_commissions(params) do
      {:ok, commissions} ->
        {Repo.paginate(commissions, pagination), SearchQuery.changeset(%SearchQuery{})}

      {:error, commissions, changeset} ->
        {Repo.paginate(commissions, pagination), changeset}
    end
  end

  @doc """
  Loads the public commission directory for `actor`.

  The `:index` commission ability is checked before searching. Results include
  only open listings with items whose active owner has recent activity.
  Invalid search parameters return an empty page and the rejected search
  changeset. If present, the viewing user is returned with commission preloaded.

  ## Examples

      iex> load_directory(actor, params, page: 1, page_size: 25)
      {:ok, %Directory{}}

  """
  @spec load_directory(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Directory.t()} | {:error, :unauthorized}
  def load_directory(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, Commission) do
      {commissions, changeset} = search_directory(params, pagination)

      {:ok,
       %Directory{
         commissions: commissions,
         changeset: changeset,
         current_user: Repo.preload(actor.user, :commission)
       }}
    end
  end

  @doc """
  Loads the active profile named by `slug` and its visible commission listing.

  Missing or deactivated profiles and profiles without a listing are not found.
  Items are returned by ascending base price with ID as a deterministic tie
  breaker.

  ## Examples

      iex> load_commission_for_show(actor, "artist")
      {:ok, %CommissionPage{}}

  """
  @spec load_commission_for_show(Actor.t(), String.t()) ::
          {:ok, CommissionPage.t()} | {:error, :unauthorized | :not_found}
  def load_commission_for_show(%Actor{} = actor, slug) do
    with {:ok, {user, commission}} <- load_commission(actor, slug, :show) do
      {:ok, commission_page(user, commission)}
    end
  end

  @doc """
  Loads a visible commission listing as a report target.

  This shares the active profile and `:show` gates used by the listing page.

  ## Examples

      iex> load_report_target(actor, "artist")
      {:ok, %Commission{}}

  """
  @spec load_report_target(Actor.t(), String.t()) ::
          {:ok, Commission.t()} | {:error, :unauthorized | :not_found}
  def load_report_target(%Actor{} = actor, slug) do
    with {:ok, %CommissionPage{commission: commission}} <-
           load_commission_for_show(actor, slug) do
      {:ok, commission}
    end
  end

  @doc """
  Builds a new commission form for the active profile named by `slug`.

  Write access is checked before loading. The owner, moderators, and admins may
  manage a commission on the profile's behalf. The profile must have a verified
  artist link and no existing commission.

  ## Examples

      iex> new_commission(actor, "artist")
      {:ok, %CommissionForm{}}

  """
  @spec new_commission(Actor.t(), String.t()) ::
          {:ok, CommissionForm.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def new_commission(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- load_new_commission(actor, slug, :new) do
      {:ok, commission_form(user, commission)}
    end
  end

  @doc """
  Creates the sole commission listing for the active profile named by `slug`.

  Authorization and verified link rules match `new_commission/2`. The database
  uniquely enforces one commission per profile. Validation failures return a
  `CommissionForm` retaining the safely loaded profile and attempted changes.

  ## Examples

      iex> create_commission(actor, "artist", attrs)
      {:ok, %CommissionPage{}}

      iex> create_commission(actor, "artist", invalid_attrs)
      {:error, %CommissionForm{}}

  """
  @spec create_commission(Actor.t(), String.t(), map()) ::
          {:ok, CommissionPage.t()}
          | {:error, CommissionForm.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def create_commission(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- load_new_commission(actor, slug, :create) do
      commission
      |> Commission.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, commission} ->
          {:ok, commission_page(user, commission)}

        {:error, changeset} ->
          {:error, commission_form(user, commission, changeset)}
      end
    end
  end

  @doc """
  Loads the existing commission form for the active profile named by `slug`.

  Write access, owner/staff authorization, and verified link requirements match
  the update operation.

  ## Examples

      iex> load_commission_for_edit(actor, "artist")
      {:ok, %CommissionForm{}}

  """
  @spec load_commission_for_edit(Actor.t(), String.t()) ::
          {:ok, CommissionForm.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def load_commission_for_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- load_manageable_commission(actor, slug, :edit) do
      {:ok, commission_form(user, commission)}
    end
  end

  @doc """
  Updates the existing commission for the active profile named by `slug`.

  Validation failures return a `CommissionForm`. Successful updates preserve
  item ordering and count.

  ## Examples

      iex> update_commission(actor, "artist", attrs)
      {:ok, %CommissionPage{}}

  """
  @spec update_commission(Actor.t(), String.t(), map()) ::
          {:ok, CommissionPage.t()}
          | {:error, CommissionForm.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links}
  def update_commission(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, commission}} <- load_manageable_commission(actor, slug, :update) do
      commission
      |> Commission.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, commission} ->
          {:ok, commission_page(user, commission)}

        {:error, changeset} ->
          {:error, commission_form(user, commission, changeset)}
      end
    end
  end

  @doc """
  Deletes the commission for the active profile named by `slug`.

  The commission, its items, and its report-target foreign keys are delete atomically.
  Open reports are closed by the acting user and reindexed only after commit.

  ## Examples

      iex> delete_commission(actor, "artist")
      {:ok, %Commission{}}

  """
  @spec delete_commission(Actor.t(), String.t()) ::
          {:ok, Commission.t()}
          | {:error, :ban | :unauthorized | :not_found | :no_verified_links | term()}
  def delete_commission(%Actor{user: closing_user} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- load_manageable_commission(actor, slug, :delete) do
      Multi.new()
      |> Reports.put_close_reports(:reports, closing_user, commission_id: commission.id)
      |> Multi.delete(:commission, commission)
      |> Multi.transact()
      |> case do
        {:ok, %{commission: commission}} ->
          {:ok, commission}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Builds a new item changeset for the commission belonging to the active profile
  named by `slug`.

  Creating commission items requires permission to edit the commission. Write access
  is checked before the profile and commission are loaded.

  ## Examples

      iex> new_item(actor, "artist")
      {:ok, %Ecto.Changeset{}}

  """
  @spec new_item(Actor.t(), String.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized | :not_found}
  def new_item(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- load_commission(actor, slug, :new_item) do
      {:ok, Item.changeset(new_item(commission))}
    end
  end

  @doc """
  Creates an item under the commission belonging to the active profile named by
  `slug` and increments the listing's item count.

  ## Examples

      iex> create_item(actor, "artist", attrs)
      {:ok, %Item{}}

      iex> create_item(actor, "artist", invalid_attrs)
      {:error, %Ecto.Changeset{}}

  """
  @spec create_item(Actor.t(), String.t(), map()) ::
          {:ok, Item.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def create_item(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- load_commission(actor, slug, :create_item) do
      changeset =
        commission
        |> new_item()
        |> Item.changeset(attrs)

      counter_query =
        Commission
        |> where(id: ^commission.id)
        |> update(inc: [commission_items_count: 1])

      Multi.new()
      |> Multi.insert(:item, changeset)
      |> Multi.update_all(:commission, counter_query, [])
      |> Multi.transact()
      |> case do
        {:ok, %{item: item}} ->
          {:ok, item}

        {:error, :item, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Loads the item named by `id` for editing under the commission belonging to
  the active profile named by `slug`.

  The item lookup is constrained by the commission before authorization.
  Malformed, absent, and wrong-commission IDs are all not found.

  ## Examples

      iex> load_item_for_edit(actor, "artist", "12")
      {:ok, %Ecto.Changeset{}}

      iex> load_item_for_edit(actor, "artist", "bad")
      {:error, :not_found}

  """
  @spec load_item_for_edit(Actor.t(), String.t(), IntegerId.integer_id()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_item_for_edit(%Actor{} = actor, slug, id) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- load_commission(actor, slug, :edit_item),
         {:ok, item} <- item_for_commission(commission, id) do
      {:ok, Item.changeset(item)}
    end
  end

  @doc """
  Updates the item named by `id` under the commission belonging to the active
  profile named by `slug`.

  The item lookup is constrained by the commission before authorization.
  Malformed, absent, and wrong-commission IDs are all not found. Validation
  failures return an `m:Ecto.Changeset`.

  ## Examples

      iex> update_item(actor, "artist", "12", attrs)
      {:ok, %Item{}}

  """
  @spec update_item(Actor.t(), String.t(), IntegerId.integer_id(), map()) ::
          {:ok, Item.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def update_item(%Actor{} = actor, slug, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- load_commission(actor, slug, :update_item),
         {:ok, item} <- item_for_commission(commission, id) do
      item
      |> Item.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Deletes the item named by `id` under the commission belonging to the active
  profile named by `slug` and decrements the listing's item count.

  Malformed, absent, and wrong-commission IDs are all not found.

  ## Examples

      iex> delete_item(actor, "artist", "12")
      {:ok, %Item{}}

  """
  @spec delete_item(Actor.t(), String.t(), IntegerId.integer_id()) ::
          {:ok, Item.t()} | {:error, :ban | :unauthorized | :not_found | term()}
  def delete_item(%Actor{} = actor, slug, id) do
    with :ok <- verify_write_access(actor),
         {:ok, {_user, commission}} <- load_commission(actor, slug, :delete_item),
         {:ok, item} <- item_for_commission(commission, id) do
      counter_query =
        Commission
        |> where(id: ^item.commission_id)
        |> update(inc: [commission_items_count: -1])

      Multi.new()
      |> Multi.delete(:item, item)
      |> Multi.update_all(:commission, counter_query, [])
      |> Multi.transact()
      |> case do
        {:ok, %{item: item}} ->
          {:ok, item}

        {:error, :item, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end
end
