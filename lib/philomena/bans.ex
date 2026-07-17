defmodule Philomena.Bans do
  @moduledoc """
  The Bans context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Attribution.Actor
  alias Philomena.Bans.Finder
  alias Philomena.Bans.Fingerprint
  alias Philomena.Bans.SubnetCreator
  alias Philomena.Bans.Subnet
  alias Philomena.Bans.User
  alias Philomena.IntegerId
  alias Philomena.ModerationLogs
  alias Philomena.Users

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
  Returns the fingerprint bans matching `fingerprint`, newest first.
  """
  @spec fingerprint_bans_for(String.t()) :: [Fingerprint.t()]
  def fingerprint_bans_for(fingerprint) do
    Fingerprint
    |> where(fingerprint: ^fingerprint)
    |> order_by(desc: :created_at)
    |> Repo.all()
  end

  # Creates a fingerprint ban. Visible for testing.
  @doc false
  def create_fingerprint(creator, attrs)

  def create_fingerprint(%Users.User{} = creator, attrs) do
    %Fingerprint{banning_user_id: creator.id}
    |> Fingerprint.changeset(attrs)
    |> Repo.insert()
  end

  def create_fingerprint(%Actor{} = actor, attrs) do
    create_fingerprint(actor.user, attrs)
  end

  # Updates a fingerprint ban.
  defp update_fingerprint(%Fingerprint{} = fingerprint, attrs) do
    fingerprint
    |> Fingerprint.changeset(attrs)
    |> Repo.update()
  end

  # Deletes a fingerprint ban.
  defp delete_fingerprint(%Fingerprint{} = fingerprint) do
    Repo.delete(fingerprint)
  end

  # Returns an `%Ecto.Changeset{}` for tracking fingerprint ban changes.
  defp change_fingerprint(%Fingerprint{} = fingerprint) do
    Fingerprint.changeset(fingerprint, %{})
  end

  @doc """
  Returns paginated fingerprint bans for the admin listing, on behalf of
  `actor`.

  Filters by the `"bq"` full-text search or the exact `"fingerprint"` branch
  when either is present in params. Results are ordered newest first.

  ## Examples

      iex> admin_fingerprint_bans(admin, params, pagination)
      {:ok, %Scrivener.Page{}}

      iex> admin_fingerprint_bans(user, params, pagination)
      {:error, :unauthorized}

  """
  @spec admin_fingerprint_bans(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Fingerprint.t())} | {:error, :unauthorized}
  def admin_fingerprint_bans(%Actor{} = actor, params, pagination) do
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

  ## Examples

      iex> new_fingerprint_ban(admin, fingerprint)
      {:ok, %Ecto.Changeset{}}

      iex> new_fingerprint_ban(user, fingerprint)
      {:error, :unauthorized}

  """
  @spec new_fingerprint_ban(Actor.t(), String.t() | nil) ::
          {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_fingerprint_ban(%Actor{} = actor, fingerprint) do
    with :ok <- authorize(actor, :new, Fingerprint) do
      {:ok, change_fingerprint(%Fingerprint{fingerprint: fingerprint})}
    end
  end

  @doc """
  Creates a fingerprint ban on behalf of `actor`.

  On success a moderation log attributing the creation to `actor` is written.

  ## Examples

      iex> create_fingerprint_ban(admin, ban_params)
      {:ok, %Fingerprint{}}

      iex> create_fingerprint_ban(admin, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_fingerprint_ban(user, ban_params)
      {:error, :unauthorized}

  """
  @spec create_fingerprint_ban(Actor.t(), map()) ::
          {:ok, Fingerprint.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_fingerprint_ban(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :create, Fingerprint),
         {:ok, fingerprint_ban} <- create_fingerprint(actor, attrs) do
      log_fingerprint_ban(actor, "Admin.FingerprintBan:create", fingerprint_ban, "Created")
      {:ok, fingerprint_ban}
    end
  end

  @doc """
  Loads the fingerprint ban named by `id` for editing, on behalf of `actor`,
  pairing it with a changeset for editing it.

  ## Examples

      iex> load_fingerprint_ban_for_edit(admin, fingerprint_ban_id)
      {:ok, {%Fingerprint{}, %Ecto.Changeset{}}}

      iex> load_fingerprint_ban_for_edit(admin, invalid_id)
      {:error, :not_found}

      iex> load_fingerprint_ban_for_edit(user, fingerprint_ban_id)
      {:error, :unauthorized}

  """
  @spec load_fingerprint_ban_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Fingerprint.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_fingerprint_ban_for_edit(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :edit, Fingerprint),
         {:ok, fingerprint_ban} <- load_fingerprint_ban(id) do
      {:ok, {fingerprint_ban, change_fingerprint(fingerprint_ban)}}
    end
  end

  @doc """
  Updates the fingerprint ban named by `id`, on behalf of `actor`.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_fingerprint_ban(admin, fingerprint_ban_id, fingerprint_ban_params)
      {:ok, %Fingerprint{}}

      iex> update_fingerprint_ban(admin, fingerprint_ban_id, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_fingerprint_ban(admin, invalid_id, fingerprint_ban_params)
      {:error, :not_found}

      iex> update_fingerprint_ban(user, fingerprint_ban_id, fingerprint_ban_params)
      {:error, :unauthorized}

  """
  @spec update_fingerprint_ban(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Fingerprint.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_fingerprint_ban(%Actor{} = actor, id, attrs) do
    with :ok <- authorize(actor, :update, Fingerprint),
         {:ok, fingerprint_ban} <- load_fingerprint_ban(id),
         {:ok, fingerprint_ban} <- update_fingerprint(fingerprint_ban, attrs) do
      log_fingerprint_ban(actor, "Admin.FingerprintBan:update", fingerprint_ban, "Updated")
      {:ok, fingerprint_ban}
    end
  end

  @doc """
  Deletes the fingerprint ban named by `id`, on behalf of `actor`.

  On success a moderation log attributing the removal to `actor` is written.

  ## Examples

      iex> delete_fingerprint_ban(admin, fingerprint_ban_id)
      {:ok, %Fingerprint{}}

      iex> delete_fingerprint_ban(admin, invalid_id)
      {:error, :not_found}

      iex> delete_fingerprint_ban(user, fingerprint_ban_id)
      {:error, :unauthorized}

  """
  @spec delete_fingerprint_ban(Actor.t(), Loader.integer_id()) ::
          {:ok, Fingerprint.t()} | {:error, :unauthorized | :not_found}
  def delete_fingerprint_ban(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :delete, Fingerprint),
         {:ok, fingerprint_ban} <- load_fingerprint_ban(id),
         :ok <- verify_can_delete(actor.user) do
      {:ok, fingerprint_ban} = delete_fingerprint(fingerprint_ban)
      log_fingerprint_ban(actor, "Admin.FingerprintBan:delete", fingerprint_ban, "Deleted")
      {:ok, fingerprint_ban}
    end
  end

  @spec load_fingerprint_ban(Loader.integer_id()) :: Loader.fetch_result(Fingerprint.t())
  defp load_fingerprint_ban(id) do
    Loader.fetch(Fingerprint, id)
  end

  @spec log_fingerprint_ban(Loader.actor(), String.t(), Fingerprint.t(), String.t()) :: any()
  defp log_fingerprint_ban(actor, type, ban, verb) do
    ModerationLogs.create_moderation_log(
      actor,
      type,
      "/admin/fingerprint_bans",
      "#{verb} a fingerprint ban #{ban.generated_ban_id}"
    )
  end

  # Creates a subnet ban.
  @doc false
  def create_subnet(creator, attrs \\ %{})

  def create_subnet(%Users.User{} = creator, attrs) do
    %Subnet{banning_user_id: creator.id}
    |> Subnet.changeset(attrs)
    |> Repo.insert()
  end

  def create_subnet(%Actor{} = actor, attrs) do
    create_subnet(actor.user, attrs)
  end

  # Updates a subnet ban.
  defp update_subnet(%Subnet{} = subnet, attrs) do
    subnet
    |> Subnet.changeset(attrs)
    |> Repo.update()
  end

  # Deletes a subnet ban.
  defp delete_subnet(%Subnet{} = subnet) do
    Repo.delete(subnet)
  end

  # Returns an `%Ecto.Changeset{}` for tracking subnet ban changes.
  # TODO: this should be a private definition but the controller uses it directly
  @doc false
  def change_subnet(%Subnet{} = subnet) do
    Subnet.changeset(subnet, %{})
  end

  @doc """
  Returns paginated subnet bans for the admin listing, on behalf of
  `actor`.

  Filters by the `"bq"` full-text search or the `"ip"` branch
  when either is present in params. Results are ordered newest first.

  ## Examples

      iex> admin_subnet_bans(admin, params, pagination)
      {:ok, %Scrivener.Page{}}

      iex> admin_subnet_bans(admin, %{"ip" => "512.512.512.512"}, pagination)
      {:error, {:invalid_ip, "512.512.512.512}}

      iex> admin_subnet_bans(user, params, pagination)
      {:error, :unauthorized}

  """
  @spec admin_subnet_bans(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Subnet.t())}
          | {:error, :unauthorized | {:invalid_ip, String.t()}}
  def admin_subnet_bans(%Actor{} = actor, params, pagination) do
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

  ## Examples

      iex> new_subnet_ban(admin, ip_or_cidr)
      {:ok, %Ecto.Changeset{}}

      iex> new_subnet_ban(admin, "512.512.512.512")
      {:error, {:invalid_ip, "512.512.512.512"}}

      iex> new_subnet_ban(user, ip_or_cidr)
      {:error, :unauthorized}

  """
  @spec new_subnet_ban(Actor.t(), String.t() | nil) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | {:invalid_ip, String.t()}}
  def new_subnet_ban(%Actor{} = actor, specification) do
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

  On success a moderation log attributing the creation to `actor` is written.

  ## Examples

      iex> create_subnet_ban(admin, ban_params)
      {:ok, %Subnet{}}

      iex> create_subnet_ban(admin, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_subnet_ban(user, ban_params)
      {:error, :unauthorized}

  """
  @spec create_subnet_ban(Actor.t(), map()) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_subnet_ban(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :create, Subnet),
         {:ok, subnet_ban} <- create_subnet(actor, attrs) do
      log_subnet_ban(actor, "Admin.SubnetBan:create", subnet_ban, "Created")
      {:ok, subnet_ban}
    end
  end

  @doc """
  Loads the subnet ban named by `id` for editing, on behalf of `actor`,
  pairing it with a changeset for editing it.

  ## Examples

      iex> load_subnet_ban_for_edit(admin, subnet_ban_id)
      {:ok, {%Subnet{}, %Ecto.Changeset{}}}

      iex> load_subnet_ban_for_edit(admin, invalid_id)
      {:error, :not_found}

      iex> load_subnet_ban_for_edit(user, subnet_ban_id)
      {:error, :unauthorized}

  """
  @spec load_subnet_ban_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Subnet.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_subnet_ban_for_edit(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :edit, Subnet),
         {:ok, subnet_ban} <- load_subnet_ban(id) do
      {:ok, {subnet_ban, change_subnet(subnet_ban)}}
    end
  end

  @doc """
  Updates the subnet ban named by `id`, on behalf of `actor`.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_subnet_ban(admin, subnet_ban_id, subnet_ban_params)
      {:ok, %Subnet{}}

      iex> update_subnet_ban(admin, subnet_ban_id, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_subnet_ban(admin, invalid_id, subnet_ban_params)
      {:error, :not_found}

      iex> update_subnet_ban(user, subnet_ban_id, subnet_ban_params)
      {:error, :unauthorized}

  """
  @spec update_subnet_ban(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_subnet_ban(%Actor{} = actor, id, attrs) do
    with :ok <- authorize(actor, :update, Subnet),
         {:ok, subnet_ban} <- load_subnet_ban(id),
         {:ok, subnet_ban} <- update_subnet(subnet_ban, attrs) do
      log_subnet_ban(actor, "Admin.SubnetBan:update", subnet_ban, "Updated")
      {:ok, subnet_ban}
    end
  end

  @doc """
  Deletes the subnet ban named by `id`, on behalf of `actor`.

  On success a moderation log attributing the removal to `actor` is written.

  ## Examples

      iex> delete_subnet_ban(admin, subnet_ban_id)
      {:ok, %Subnet{}}

      iex> delete_subnet_ban(admin, invalid_id)
      {:error, :not_found}

      iex> delete_subnet_ban(user, subnet_ban_id)
      {:error, :unauthorized}

  """
  @spec delete_subnet_ban(Actor.t(), Loader.integer_id()) ::
          {:ok, Subnet.t()} | {:error, :unauthorized | :not_found}
  def delete_subnet_ban(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :delete, Subnet),
         {:ok, subnet_ban} <- load_subnet_ban(id),
         :ok <- verify_can_delete(actor.user) do
      {:ok, subnet_ban} = delete_subnet(subnet_ban)
      log_subnet_ban(actor, "Admin.SubnetBan:delete", subnet_ban, "Deleted")
      {:ok, subnet_ban}
    end
  end

  @spec load_subnet_ban(Loader.integer_id()) :: Loader.fetch_result(Subnet.t())
  defp load_subnet_ban(id) do
    Loader.fetch(Subnet, id)
  end

  @spec log_subnet_ban(Loader.actor(), String.t(), Subnet.t(), String.t()) :: any()
  defp log_subnet_ban(actor, type, ban, verb) do
    ModerationLogs.create_moderation_log(
      actor,
      type,
      "/admin/subnet_bans",
      "#{verb} a subnet ban #{ban.generated_ban_id}"
    )
  end

  # Creates a user ban. Visible for testing.
  @doc false
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

  # Updates a user ban.
  defp update_user(%User{} = user, attrs) do
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

  # Deletes a user ban.
  defp delete_user(%User{} = user) do
    Repo.delete(user)
    |> case do
      {:ok, user} ->
        Users.reindex_user(%Users.User{id: user.user_id})

        {:ok, user}

      error ->
        error
    end
  end

  # Returns an `%Ecto.Changeset{}` for tracking user ban changes.
  defp change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  @doc """
  Returns paginated user bans for the admin listing, on behalf of
  `actor`.

  Filters by the `"bq"` full-text search or the exact `"user_id"` branch
  when either is present in params. Results are ordered newest first.

  ## Examples

      iex> admin_user_bans(admin, params, pagination)
      {:ok, %Scrivener.Page{}}

      iex> admin_user_bans(user, params, pagination)
      {:error, :unauthorized}

  """
  @spec admin_user_bans(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(User.t())} | {:error, :unauthorized}
  def admin_user_bans(%Actor{} = actor, params, pagination) do
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

  ## Example

      iex> target_user(user_id)
      %User{}

      iex> target_user(invalid_id)
      nil

  """
  @spec target_user(Loader.integer_id()) :: Users.User.t() | nil
  def target_user(id) do
    # TODO: get rid of this?
    case IntegerId.parse(id) do
      {:ok, id} -> Repo.get(Users.User, id)
      :error -> nil
    end
  end

  @doc """
  Builds a changeset for a new user ban on behalf of `actor`, prefilling
  the user from the `user_id` argument.

  ## Examples

      iex> new_user_ban(admin, user_id)
      {:ok, {%Users.User{}, %Ecto.Changeset{}}}

      iex> new_user_ban(admin, invalid_user_id)
      {:error, :no_target}

      iex> new_user_ban(user, user_id)
      {:error, :unauthorized}

  """
  @spec new_user_ban(Actor.t(), Loader.integer_id()) ::
          {:ok, {Users.User.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :no_target}
  def new_user_ban(%Actor{} = actor, user_id) do
    with :ok <- authorize(actor, :new, User) do
      case target_user(user_id) do
        nil -> {:error, :no_target}
        target -> {:ok, {target, change_user(Ecto.build_assoc(target, :bans))}}
      end
    end
  end

  @doc """
  Creates a user ban on behalf of `actor`.

  On success a moderation log attributing the creation to `actor` is written.

  ## Examples

      iex> create_user_ban(admin, ban_params)
      {:ok, %User{}}

      iex> create_user_ban(admin, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_user_ban(user, ban_params)
      {:error, :unauthorized}

  """
  @spec create_user_ban(Actor.t(), map()) ::
          {:ok, User.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_user_ban(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :create, User),
         {:ok, user_ban} <- create_user(actor.user, attrs) do
      log_user_ban(actor, "Admin.UserBan:create", user_ban, "Created")
      {:ok, user_ban}
    end
  end

  @doc """
  Loads the user ban named by `id` for editing, on behalf of `actor`,
  pairing it with a changeset for editing it.

  ## Examples

      iex> load_user_ban_for_edit(admin, user_ban_id)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_user_ban_for_edit(admin, invalid_id)
      {:error, :not_found}

      iex> load_user_ban_for_edit(user, user_ban_id)
      {:error, :unauthorized}

  """
  @spec load_user_ban_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_user_ban_for_edit(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :edit, User),
         {:ok, user_ban} <- load_user_ban(id, [:user]) do
      {:ok, {user_ban, change_user(user_ban)}}
    end
  end

  @doc """
  Updates the user ban named by `id`, on behalf of `actor`.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_user_ban(admin, user_ban_id, user_ban_params)
      {:ok, %User{}}

      iex> update_user_ban(admin, user_ban_id, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_user_ban(admin, invalid_id, user_ban_params)
      {:error, :not_found}

      iex> update_user_ban(user, user_ban_id, user_ban_params)
      {:error, :unauthorized}

  """
  @spec update_user_ban(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_user_ban(%Actor{} = actor, id, attrs) do
    with :ok <- authorize(actor, :update, User),
         {:ok, user_ban} <- load_user_ban(id, [:user]),
         {:ok, user_ban} <- update_user(user_ban, attrs) do
      log_user_ban(actor, "Admin.UserBan:update", user_ban, "Updated")
      {:ok, user_ban}
    end
  end

  @doc """
  Deletes the user ban named by `id`, on behalf of `actor`.

  On success a moderation log attributing the removal to `actor` is written.

  ## Examples

      iex> delete_user_ban(admin, user_ban_id)
      {:ok, %User{}}

      iex> delete_user_ban(admin, invalid_id)
      {:error, :not_found}

      iex> delete_user_ban(user, user_ban_id)
      {:error, :unauthorized}

  """
  @spec delete_user_ban(Actor.t(), Loader.integer_id()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def delete_user_ban(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :delete, User),
         {:ok, user_ban} <- load_user_ban(id, []),
         :ok <- verify_can_delete(actor.user) do
      {:ok, user_ban} = delete_user(user_ban)
      log_user_ban(actor, "Admin.UserBan:delete", user_ban, "Deleted")
      {:ok, user_ban}
    end
  end

  @spec load_user_ban(Loader.integer_id(), list()) :: Loader.fetch_result(User.t())
  defp load_user_ban(id, preloads) do
    Loader.fetch(User, id, preloads)
  end

  @spec log_user_ban(Loader.actor(), String.t(), User.t(), String.t()) :: any()
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
  # TODO: this is probably an unnecessary constraint
  defp verify_can_delete(%Users.User{role: "admin"}), do: :ok
  defp verify_can_delete(_actor), do: {:error, :unauthorized}
end
