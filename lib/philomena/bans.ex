defmodule Philomena.Bans do
  @moduledoc """
  The Bans context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Bans.Finder
  alias Philomena.Bans.Fingerprint
  alias Philomena.Bans.SubnetCreator
  alias Philomena.Bans.Subnet
  alias Philomena.Bans.User
  alias Philomena.IntegerId
  alias Philomena.ModerationLogs
  alias Philomena.Users

  @doc """
  Returns the list of fingerprint bans.

  ## Examples

      iex> list_fingerprint_bans()
      [%Fingerprint{}, ...]

  """
  def list_fingerprint_bans do
    Repo.all(Fingerprint)
  end

  @doc """
  Returns the fingerprint bans matching `fingerprint`, newest first.
  """
  @spec fingerprint_bans_for(String.t()) :: [Fingerprint.t()]
  def fingerprint_bans_for(fingerprint) do
    Fingerprint
    |> where(fingerprint: ^fingerprint)
    |> order_by(desc: :created_at)
    |> Repo.all()
  end

  @doc """
  Returns the subnet bans whose specification contains `ip`, newest first.
  """
  @spec subnet_bans_for_ip(Postgrex.INET.t()) :: [Subnet.t()]
  def subnet_bans_for_ip(ip) do
    Subnet
    |> where([s], fragment("? >>= ?", s.specification, ^ip))
    |> order_by(desc: :created_at)
    |> Repo.all()
  end

  @doc """
  Gets a single fingerprint ban.

  Raises `Ecto.NoResultsError` if the fingerprint ban does not exist.

  ## Examples

      iex> get_fingerprint!(123)
      %Fingerprint{}

      iex> get_fingerprint!(456)
      ** (Ecto.NoResultsError)

  """
  def get_fingerprint!(id), do: Repo.get!(Fingerprint, id)

  @doc """
  Creates a fingerprint ban.

  ## Examples

      iex> create_fingerprint(%{field: value})
      {:ok, %Fingerprint{}}

      iex> create_fingerprint(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_fingerprint(creator, attrs \\ %{}) do
    %Fingerprint{banning_user_id: creator.id}
    |> Fingerprint.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a fingerprint ban.

  ## Examples

      iex> update_fingerprint(fingerprint, %{field: new_value})
      {:ok, %Fingerprint{}}

      iex> update_fingerprint(fingerprint, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_fingerprint(%Fingerprint{} = fingerprint, attrs) do
    fingerprint
    |> Fingerprint.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a fingerprint ban.

  ## Examples

      iex> delete_fingerprint(fingerprint)
      {:ok, %Fingerprint{}}

      iex> delete_fingerprint(fingerprint)
      {:error, %Ecto.Changeset{}}

  """
  def delete_fingerprint(%Fingerprint{} = fingerprint) do
    Repo.delete(fingerprint)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking fingerprint ban changes.

  ## Examples

      iex> change_fingerprint(fingerprint)
      %Ecto.Changeset{source: %Fingerprint{}}

  """
  def change_fingerprint(%Fingerprint{} = fingerprint) do
    Fingerprint.changeset(fingerprint, %{})
  end

  @doc """
  Returns the paginated fingerprint bans for the admin listing, on behalf of
  `actor`.

  Authorizes `:index` against the fingerprint-ban model, then filters by the
  `"bq"` full-text search or the exact `"fingerprint"` branch when either is
  present, newest first. Returns `{:ok, fingerprint_bans}` as a
  `m:Scrivener.Page` or `{:error, :unauthorized}`.
  """
  @spec admin_fingerprint_bans(Users.User.t() | nil, map(), map() | keyword()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def admin_fingerprint_bans(actor, params, pagination) do
    with :ok <- authorize(actor, :index, Fingerprint) do
      fingerprint_bans =
        params
        |> fingerprint_bans_query()
        |> order_by(desc: :created_at)
        |> preload(:banning_user)
        |> Repo.paginate(pagination)

      {:ok, fingerprint_bans}
    end
  end

  defp fingerprint_bans_query(%{"bq" => q}) when is_binary(q) do
    where(
      Fingerprint,
      [fb],
      ilike(fb.fingerprint, ^"%#{q}%") or
        fb.generated_ban_id == ^q or
        fragment("to_tsvector(?) @@ plainto_tsquery(?)", fb.reason, ^q) or
        fragment("to_tsvector(?) @@ plainto_tsquery(?)", fb.note, ^q)
    )
  end

  defp fingerprint_bans_query(%{"fingerprint" => fingerprint}) when is_binary(fingerprint) do
    where(Fingerprint, fingerprint: ^fingerprint)
  end

  defp fingerprint_bans_query(_params), do: Fingerprint

  @doc """
  Builds a changeset for a new fingerprint ban on behalf of `actor`, prefilling
  the fingerprint from the `fingerprint` argument (which may be `nil`).

  Authorizes `:new` against the fingerprint-ban model. Returns
  `{:ok, changeset}` or `{:error, :unauthorized}`.
  """
  @spec new_fingerprint_ban(Users.User.t() | nil, any()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_fingerprint_ban(actor, fingerprint) do
    with :ok <- authorize(actor, :new, Fingerprint) do
      {:ok, change_fingerprint(%Fingerprint{fingerprint: fingerprint})}
    end
  end

  @doc """
  Creates a fingerprint ban on behalf of `actor`.

  Authorizes `:create` against the fingerprint-ban model, inserts the ban
  through `create_fingerprint/2`, and writes an `"Admin.FingerprintBan:create"`
  moderation log on success.

  Returns `{:ok, fingerprint_ban}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_fingerprint_ban(Users.User.t() | nil, map()) ::
          {:ok, Fingerprint.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_fingerprint_ban(actor, attrs) do
    with :ok <- authorize(actor, :create, Fingerprint),
         {:ok, fingerprint_ban} <- create_fingerprint(actor, attrs) do
      log_fingerprint_ban(actor, "Admin.FingerprintBan:create", fingerprint_ban, "Created")
      {:ok, fingerprint_ban}
    end
  end

  @doc """
  Loads the fingerprint ban named by `id` for editing, on behalf of `actor`,
  pairing it with a changeset for editing it.

  Authorizes `:edit` against the fingerprint-ban model, then loads the ban.
  Returns `{:ok, {fingerprint_ban, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}` for a non-castable or unknown id.
  """
  @spec load_fingerprint_ban_for_edit(Users.User.t() | nil, any()) ::
          {:ok, {Fingerprint.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_fingerprint_ban_for_edit(actor, id) do
    with :ok <- authorize(actor, :edit, Fingerprint),
         {:ok, fingerprint_ban} <- load_fingerprint_ban(id) do
      {:ok, {fingerprint_ban, change_fingerprint(fingerprint_ban)}}
    end
  end

  @doc """
  Updates the fingerprint ban named by `id`, on behalf of `actor`.

  Authorizes `:update` against the fingerprint-ban model, loads the ban, applies
  the update through `update_fingerprint/2`, and writes an
  `"Admin.FingerprintBan:update"` moderation log on success.

  Returns `{:ok, fingerprint_ban}`, `{:error, :unauthorized}`,
  `{:error, :not_found}`, or `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_fingerprint_ban(Users.User.t() | nil, any(), map()) ::
          {:ok, Fingerprint.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_fingerprint_ban(actor, id, attrs) do
    with :ok <- authorize(actor, :update, Fingerprint),
         {:ok, fingerprint_ban} <- load_fingerprint_ban(id),
         {:ok, fingerprint_ban} <- update_fingerprint(fingerprint_ban, attrs) do
      log_fingerprint_ban(actor, "Admin.FingerprintBan:update", fingerprint_ban, "Updated")
      {:ok, fingerprint_ban}
    end
  end

  @doc """
  Deletes the fingerprint ban named by `id`, on behalf of `actor`.

  Authorizes `:delete` against the fingerprint-ban model, loads the ban, and
  requires `actor` to be an admin. Writes an `"Admin.FingerprintBan:delete"`
  moderation log on success.

  Returns `{:ok, fingerprint_ban}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec delete_fingerprint_ban(Users.User.t() | nil, any()) ::
          {:ok, Fingerprint.t()} | {:error, :unauthorized | :not_found}
  def delete_fingerprint_ban(actor, id) do
    with :ok <- authorize(actor, :delete, Fingerprint),
         {:ok, fingerprint_ban} <- load_fingerprint_ban(id),
         :ok <- verify_can_delete(actor) do
      {:ok, fingerprint_ban} = delete_fingerprint(fingerprint_ban)
      log_fingerprint_ban(actor, "Admin.FingerprintBan:delete", fingerprint_ban, "Deleted")
      {:ok, fingerprint_ban}
    end
  end

  defp load_fingerprint_ban(id) do
    Loader.fetch(Fingerprint, id)
  end

  defp log_fingerprint_ban(actor, type, ban, verb) do
    ModerationLogs.create_moderation_log(
      actor,
      type,
      "/admin/fingerprint_bans",
      "#{verb} a fingerprint ban #{ban.generated_ban_id}"
    )
  end

  @doc """
  Returns the list of subnet bans.

  ## Examples

      iex> list_subnet_bans()
      [%Subnet{}, ...]

  """
  def list_subnet_bans do
    Repo.all(Subnet)
  end

  @doc """
  Gets a single subnet ban.

  Raises `Ecto.NoResultsError` if the subnet ban does not exist.

  ## Examples

      iex> get_subnet!(123)
      %Subnet{}

      iex> get_subnet!(456)
      ** (Ecto.NoResultsError)

  """
  def get_subnet!(id), do: Repo.get!(Subnet, id)

  @doc """
  Creates a subnet ban.

  ## Examples

      iex> create_subnet(%{field: value})
      {:ok, %Subnet{}}

      iex> create_subnet(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_subnet(creator, attrs \\ %{}) do
    %Subnet{banning_user_id: creator.id}
    |> Subnet.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a subnet ban.

  ## Examples

      iex> update_subnet(subnet, %{field: new_value})
      {:ok, %Subnet{}}

      iex> update_subnet(subnet, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_subnet(%Subnet{} = subnet, attrs) do
    subnet
    |> Subnet.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a subnet ban.

  ## Examples

      iex> delete_subnet(subnet)
      {:ok, %Subnet{}}

      iex> delete_subnet(subnet)
      {:error, %Ecto.Changeset{}}

  """
  def delete_subnet(%Subnet{} = subnet) do
    Repo.delete(subnet)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking subnet ban changes.

  ## Examples

      iex> change_subnet(subnet)
      %Ecto.Changeset{source: %Subnet{}}

  """
  def change_subnet(%Subnet{} = subnet) do
    Subnet.changeset(subnet, %{})
  end

  @doc """
  Returns the paginated subnet bans for the admin listing, on behalf of `actor`.

  Authorizes `:index` against the subnet-ban model, then filters by the `"bq"`
  full-text search or by the `"ip"` branch (subnet bans containing the address)
  when either is present, newest first. Returns `{:ok, subnet_bans}` as a
  `m:Scrivener.Page`, `{:error, :unauthorized}`, or `{:error, {:invalid_ip, ip}}`
  when the `"ip"` branch value is not a valid address or CIDR range.
  """
  @spec admin_subnet_bans(Users.User.t() | nil, map(), map() | keyword()) ::
          {:ok, Scrivener.Page.t()}
          | {:error, :unauthorized | {:invalid_ip, String.t()}}
  def admin_subnet_bans(actor, params, pagination) do
    with :ok <- authorize(actor, :index, Subnet),
         {:ok, query} <- subnet_bans_query(params) do
      subnet_bans =
        query
        |> order_by(desc: :created_at)
        |> preload(:banning_user)
        |> Repo.paginate(pagination)

      {:ok, subnet_bans}
    end
  end

  defp subnet_bans_query(%{"bq" => q}) when is_binary(q) do
    query =
      where(
        Subnet,
        [sb],
        sb.generated_ban_id == ^q or
          fragment("to_tsvector(?) @@ plainto_tsquery(?)", sb.reason, ^q) or
          fragment("to_tsvector(?) @@ plainto_tsquery(?)", sb.note, ^q)
      )

    {:ok, query}
  end

  defp subnet_bans_query(%{"ip" => ip}) when is_binary(ip) do
    case EctoNetwork.INET.cast(ip) do
      {:ok, ip} ->
        {:ok, where(Subnet, [sb], fragment("? >>= ?", sb.specification, ^ip))}

      _error ->
        {:error, {:invalid_ip, ip}}
    end
  end

  defp subnet_bans_query(_params), do: {:ok, Subnet}

  @doc """
  Prepares a new subnet ban on behalf of `actor`, prefilling the specification
  from the `specification` argument (which may be `nil`).

  Authorizes `:new` against the subnet-ban model, then casts the specification.
  Returns `{:ok, %Subnet{}}` (blank, or with the parsed specification),
  `{:error, :unauthorized}`, or `{:error, {:invalid_ip, ip}}` when the
  specification is not a valid address or CIDR range.
  """
  @spec new_subnet_ban(Users.User.t() | nil, any()) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | {:invalid_ip, String.t()}}
  def new_subnet_ban(actor, specification) do
    with :ok <- authorize(actor, :new, Subnet) do
      new_subnet_from_specification(specification)
    end
  end

  defp new_subnet_from_specification(ip) when is_binary(ip) do
    case EctoNetwork.INET.cast(ip) do
      {:ok, ip} -> {:ok, %Subnet{specification: ip}}
      _error -> {:error, {:invalid_ip, ip}}
    end
  end

  defp new_subnet_from_specification(_specification), do: {:ok, %Subnet{}}

  @doc """
  Creates a subnet ban on behalf of `actor`.

  Authorizes `:create` against the subnet-ban model, inserts the ban through
  `create_subnet/2`, and writes an `"Admin.SubnetBan:create"` moderation log on
  success.

  Returns `{:ok, subnet_ban}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_subnet_ban(Users.User.t() | nil, map()) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_subnet_ban(actor, attrs) do
    with :ok <- authorize(actor, :create, Subnet),
         {:ok, subnet_ban} <- create_subnet(actor, attrs) do
      log_subnet_ban(actor, "Admin.SubnetBan:create", subnet_ban, "Created")
      {:ok, subnet_ban}
    end
  end

  @doc """
  Loads the subnet ban named by `id` for editing, on behalf of `actor`, pairing
  it with a changeset for editing it.

  Authorizes `:edit` against the subnet-ban model, then loads the ban. Returns
  `{:ok, {subnet_ban, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}` for a non-castable or unknown id.
  """
  @spec load_subnet_ban_for_edit(Users.User.t() | nil, any()) ::
          {:ok, {Subnet.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_subnet_ban_for_edit(actor, id) do
    with :ok <- authorize(actor, :edit, Subnet),
         {:ok, subnet_ban} <- load_subnet_ban(id) do
      {:ok, {subnet_ban, change_subnet(subnet_ban)}}
    end
  end

  @doc """
  Updates the subnet ban named by `id`, on behalf of `actor`.

  Authorizes `:update` against the subnet-ban model, loads the ban, applies the
  update through `update_subnet/2`, and writes an `"Admin.SubnetBan:update"`
  moderation log on success.

  Returns `{:ok, subnet_ban}`, `{:error, :unauthorized}`, `{:error, :not_found}`,
  or `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_subnet_ban(Users.User.t() | nil, any(), map()) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_subnet_ban(actor, id, attrs) do
    with :ok <- authorize(actor, :update, Subnet),
         {:ok, subnet_ban} <- load_subnet_ban(id),
         {:ok, subnet_ban} <- update_subnet(subnet_ban, attrs) do
      log_subnet_ban(actor, "Admin.SubnetBan:update", subnet_ban, "Updated")
      {:ok, subnet_ban}
    end
  end

  @doc """
  Deletes the subnet ban named by `id`, on behalf of `actor`.

  Authorizes `:delete` against the subnet-ban model, loads the ban, and requires
  `actor` to be an admin. Writes an `"Admin.SubnetBan:delete"` moderation log on
  success.

  Returns `{:ok, subnet_ban}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec delete_subnet_ban(Users.User.t() | nil, any()) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | :not_found}
  def delete_subnet_ban(actor, id) do
    with :ok <- authorize(actor, :delete, Subnet),
         {:ok, subnet_ban} <- load_subnet_ban(id),
         :ok <- verify_can_delete(actor) do
      {:ok, subnet_ban} = delete_subnet(subnet_ban)
      log_subnet_ban(actor, "Admin.SubnetBan:delete", subnet_ban, "Deleted")
      {:ok, subnet_ban}
    end
  end

  defp load_subnet_ban(id) do
    Loader.fetch(Subnet, id)
  end

  defp log_subnet_ban(actor, type, ban, verb) do
    ModerationLogs.create_moderation_log(
      actor,
      type,
      "/admin/subnet_bans",
      "#{verb} a subnet ban #{ban.generated_ban_id}"
    )
  end

  @doc """
  Returns the list of user bans.

  ## Examples

      iex> list_user_bans()
      [%User{}, ...]

  """
  def list_user_bans do
    Repo.all(User)
  end

  @doc """
  Gets a single user ban.

  Raises `Ecto.NoResultsError` if the user ban does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Creates a user ban.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(creator, attrs \\ %{}) do
    changeset =
      %User{banning_user_id: creator.id}
      |> User.changeset(attrs)

    Multi.new()
    |> Multi.insert(:user_ban, changeset)
    |> Multi.run(:subnet_ban, fn _repo, %{user_ban: %{user_id: user_id}} ->
      SubnetCreator.create_for_user(creator, user_id, attrs)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user_ban: user_ban}} ->
        Users.reindex_user(%Users.User{id: user_ban.user_id})

        {:ok, user_ban}

      {:error, :user_ban, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Updates a user ban.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        Users.reindex_user(%Users.User{id: user.user_id})

        {:ok, user}

      error ->
        error
    end
  end

  @doc """
  Deletes a user ban.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
    |> case do
      {:ok, user} ->
        Users.reindex_user(%Users.User{id: user.user_id})

        {:ok, user}

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user ban changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{source: %User{}}

  """
  def change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  @doc """
  Returns the paginated user bans for the admin listing, on behalf of `actor`.

  Authorizes `:index` against the user-ban model, then filters by the `"bq"`
  full-text search or the `"user_id"` branch when either is present, newest
  first. Returns `{:ok, user_bans}` as a `m:Scrivener.Page` or
  `{:error, :unauthorized}`.
  """
  @spec admin_user_bans(Users.User.t() | nil, map(), map() | keyword()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def admin_user_bans(actor, params, pagination) do
    with :ok <- authorize(actor, :index, User) do
      user_bans =
        params
        |> user_bans_query()
        |> order_by(desc: :created_at)
        |> preload([:user, :banning_user])
        |> Repo.paginate(pagination)

      {:ok, user_bans}
    end
  end

  defp user_bans_query(%{"bq" => q}) when is_binary(q) do
    like_q = "%#{q}%"

    User
    |> join(:inner, [ub], _ in assoc(ub, :user))
    |> where(
      [ub, u],
      ilike(u.name, ^like_q) or
        ub.generated_ban_id == ^q or
        fragment("to_tsvector(?) @@ plainto_tsquery(?)", ub.reason, ^q) or
        fragment("to_tsvector(?) @@ plainto_tsquery(?)", ub.note, ^q)
    )
  end

  defp user_bans_query(%{"user_id" => user_id}) when is_binary(user_id) do
    where(User, user_id: ^user_id)
  end

  defp user_bans_query(_params), do: User

  @doc """
  Looks up the user a ban is being created against, by `id`.

  Returns the `m:Philomena.Users.User`, or `nil` when `id` is non-castable or
  names no user.
  """
  @spec target_user(any()) :: Users.User.t() | nil
  def target_user(id) do
    case IntegerId.parse(id) do
      {:ok, id} -> Repo.get(Users.User, id)
      :error -> nil
    end
  end

  @doc """
  Builds a changeset for a new user ban on behalf of `actor`, targeting the user
  named by the `user_id` (which may be `nil`).

  Authorizes `:new` against the user-ban model, then resolves the target user.
  Returns `{:ok, {target_user, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :no_target}` when `user_id` names no user (a ban must have a target).
  """
  @spec new_user_ban(Users.User.t() | nil, any()) ::
          {:ok, {Users.User.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :no_target}
  def new_user_ban(actor, user_id) do
    with :ok <- authorize(actor, :new, User) do
      case target_user(user_id) do
        nil -> {:error, :no_target}
        target -> {:ok, {target, change_user(Ecto.build_assoc(target, :bans))}}
      end
    end
  end

  @doc """
  Creates a user ban on behalf of `actor`.

  Authorizes `:create` against the user-ban model, inserts the ban and its
  automatic subnet ban through `create_user/2`, and writes an
  `"Admin.UserBan:create"` moderation log on success.

  Returns `{:ok, user_ban}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_user_ban(Users.User.t() | nil, map()) ::
          {:ok, User.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_user_ban(actor, attrs) do
    with :ok <- authorize(actor, :create, User),
         {:ok, user_ban} <- create_user(actor, attrs) do
      log_user_ban(actor, "Admin.UserBan:create", user_ban, "Created")
      {:ok, user_ban}
    end
  end

  @doc """
  Loads the user ban named by `id` for editing, on behalf of `actor`, pairing it
  (with the banned user preloaded) with a changeset for editing it.

  Authorizes `:edit` against the user-ban model, then loads the ban. Returns
  `{:ok, {user_ban, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}` for a non-castable or unknown id.
  """
  @spec load_user_ban_for_edit(Users.User.t() | nil, any()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_user_ban_for_edit(actor, id) do
    with :ok <- authorize(actor, :edit, User),
         {:ok, user_ban} <- load_user_ban(id, [:user]) do
      {:ok, {user_ban, change_user(user_ban)}}
    end
  end

  @doc """
  Updates the user ban named by `id`, on behalf of `actor`.

  Authorizes `:update` against the user-ban model, loads the ban, applies the
  update through `update_user/2`, and writes an `"Admin.UserBan:update"`
  moderation log on success.

  Returns `{:ok, user_ban}`, `{:error, :unauthorized}`, `{:error, :not_found}`,
  or `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_user_ban(Users.User.t() | nil, any(), map()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_user_ban(actor, id, attrs) do
    with :ok <- authorize(actor, :update, User),
         {:ok, user_ban} <- load_user_ban(id, [:user]),
         {:ok, user_ban} <- update_user(user_ban, attrs) do
      log_user_ban(actor, "Admin.UserBan:update", user_ban, "Updated")
      {:ok, user_ban}
    end
  end

  @doc """
  Deletes the user ban named by `id`, on behalf of `actor`.

  Authorizes `:delete` against the user-ban model, loads the ban, and requires
  `actor` to be an admin: a moderator may create and edit bans but not delete
  them. Writes an `"Admin.UserBan:delete"` moderation log on success.

  Returns `{:ok, user_ban}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec delete_user_ban(Users.User.t() | nil, any()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def delete_user_ban(actor, id) do
    with :ok <- authorize(actor, :delete, User),
         {:ok, user_ban} <- load_user_ban(id, []),
         :ok <- verify_can_delete(actor) do
      {:ok, user_ban} = delete_user(user_ban)
      log_user_ban(actor, "Admin.UserBan:delete", user_ban, "Deleted")
      {:ok, user_ban}
    end
  end

  defp load_user_ban(id, preloads) do
    Loader.fetch(User, id, preloads)
  end

  defp log_user_ban(actor, type, ban, verb) do
    ModerationLogs.create_moderation_log(
      actor,
      type,
      "/admin/user_bans",
      "#{verb} a user ban #{ban.generated_ban_id}"
    )
  end

  @doc """
  Returns the first ban, if any, matching the given user, IP, and fingerprint.
  """
  def find(user, ip, fingerprint) do
    Finder.find(user, ip, fingerprint)
  end

  # Deleting any ban is restricted to admins; other management actions are open
  # to moderators.
  defp verify_can_delete(%Users.User{role: "admin"}), do: :ok
  defp verify_can_delete(_actor), do: {:error, :unauthorized}
end
