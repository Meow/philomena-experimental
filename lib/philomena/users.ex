defmodule Philomena.Users do
  @moduledoc """
  Owns authentication, registration, profiles, account settings, and staff user
  management.

  Request-facing profile and management services accept an `Actor` first, use
  safe ID or slug locators, and authorize a loaded user with an action-specific
  ability. Authentication token services deliberately have no actor because the
  token is the credential. Loaded-record entry points are limited to explicit
  worker, indexing, filter, and erasure collaboration services.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Schema.Approval
  alias PhilomenaQuery.Search
  alias Philomena.Users

  alias Philomena.Users.{
    AdminUserForm,
    AliasMatches,
    Settings,
    Uploader,
    User,
    UserForm,
    UserNotifier,
    UserToken
  }

  alias Philomena.{Forums, Forums.Forum}
  alias Philomena.Bans
  alias Philomena.Topics
  alias Philomena.Roles.Role
  alias Philomena.UserIps.UserIp
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.UserNameChanges
  alias Philomena.UserNameChanges.UserNameChange
  alias Philomena.Images
  alias Philomena.Comments
  alias Philomena.Posts
  alias Philomena.Galleries
  alias Philomena.Reports
  alias Philomena.Filters
  alias Philomena.TagChanges
  alias Philomena.Filters.Filter
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.IndexWorker
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.UserEraseWorker
  alias Philomena.UserRenameWorker
  alias Philomena.UserUnvoteWorker
  alias Philomena.UserWipeWorker

  @typedoc """
  Describes the entity performing the action.
  The term `principal` was borrowed from AWS IAM terminology.
  """
  @type principal :: [
          ip: EctoNetwork.INET.t(),
          fingerprint: String.t(),
          user: %User{} | nil
        ]

  @user_search_fields ~W(
    name
    confirmed_at
    updated_at
    deleted_at
    images_count
    image_faves_count
    comments_count
    image_votes_count
    metadata_updates_count
    posts_count
    topics_count
    _score
  )

  # Shared forms, locators, and staff transaction composition.

  defp user_form(%User{} = user, changeset \\ nil) do
    %UserForm{user: user, changeset: changeset || User.changeset(user, %{})}
  end

  defp admin_user_form(%User{} = user, changeset \\ nil) do
    %AdminUserForm{
      user: user,
      changeset: changeset || User.changeset(user, %{}),
      roles: Repo.all(Role)
    }
  end

  defp load_user_by_slug(actor, action, slug, preloads \\ [])

  defp load_user_by_slug(actor, action, slug, preloads) when is_binary(slug) do
    User
    |> where([user], user.slug == ^slug)
    |> preload(^preloads)
    |> Loader.one_and_authorize(actor, action)
  end

  defp load_user_by_slug(_actor, _action, _slug, _preloads), do: {:error, :not_found}

  defp managed_user_transaction(actor, slug, action, mutation, log_type, log_body) do
    with :ok <- verify_write_access(actor) do
      Repo.transact(fn ->
        with {:ok, user} <- load_user_by_slug(actor, action, slug),
             {:ok, user} <- mutation.(user),
             {:ok, _log} <-
               ModerationLogs.create_moderation_log(
                 actor,
                 log_type,
                 Paths.profile_path(user),
                 log_body.(user)
               ) do
          {:ok, user}
        end
      end)
      |> reindex_transaction_result()
    end
  end

  defp logged_managed_user(actor, slug, action, log_type, log_body) do
    with :ok <- verify_write_access(actor) do
      Repo.transact(fn ->
        with {:ok, user} <- load_user_by_slug(actor, action, slug),
             {:ok, _log} <-
               ModerationLogs.create_moderation_log(
                 actor,
                 log_type,
                 Paths.profile_path(user),
                 log_body.(user)
               ) do
          {:ok, user}
        end
      end)
    end
  end

  defp reindex_transaction_result({:ok, %User{} = user}) do
    reindex_user(user)
    {:ok, user}
  end

  defp reindex_transaction_result(error), do: error

  # Authentication and token transaction composition.

  defp maybe_send_unlock_instructions(%{failed_attempts: attempts}, _unlock_url_fun)
       when attempts < 10 do
    nil
  end

  defp maybe_send_unlock_instructions(%User{} = user, unlock_url_fun) do
    user
    |> User.lock_changeset()
    |> Repo.update!()
    |> reindex_user()
    |> deliver_user_unlock_instructions(unlock_url_fun)

    nil
  end

  defp user_email_multi(user, email, context) do
    changeset = user |> User.email_changeset(%{email: email}) |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, [context]))
  end

  defp unlock_user_multi(user) do
    changeset = User.unlock_changeset(user)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["unlock"]))
  end

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  # Settings, role assignment, and user-search mechanics.

  defp change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  defp update_user_changeset(user, attrs) do
    with {:ok, role_ids} <- parse_role_ids(attrs["roles"]),
         {:ok, roles} <- load_roles(role_ids) do
      User.update_changeset(user, attrs, roles)
    else
      :error ->
        user = Repo.preload(user, :roles)

        user
        |> User.update_changeset(attrs, user.roles)
        |> Ecto.Changeset.add_error(:roles, "contains an invalid role")
    end
  end

  defp parse_role_ids(nil), do: {:ok, []}

  defp parse_role_ids(roles) when is_list(roles) do
    roles
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn role_id, {:ok, ids} ->
      case IntegerId.parse(role_id) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.uniq(ids)}
      :error -> :error
    end
  end

  defp parse_role_ids(_roles), do: :error

  defp load_roles([]), do: {:ok, []}

  defp load_roles(role_ids) do
    roles = Role |> where([role], role.id in ^role_ids) |> Repo.all()

    if length(roles) == length(role_ids), do: {:ok, roles}, else: :error
  end

  defp user_search_sort(params) do
    direction = user_search_direction(params)

    case params do
      %{"sf" => sf} when sf in @user_search_fields ->
        [%{sf => direction}, %{"id" => direction}]

      _ ->
        [%{"id" => direction}]
    end
  end

  defp user_search_direction(%{"sd" => sd}) when sd in ~W(asc desc), do: sd

  defp user_search_direction(_params), do: "desc"

  # Profile, avatar, and rename persistence mechanics.

  defp alias_matches(user) do
    # N.B.: subquery runs faster and is easier to read
    # than the equivalent join, but Ecto doesn't support
    # that for some reason (and ActiveRecord does??)

    ip_matches =
      User
      |> join(:inner, [u], _ in assoc(u, :user_ips))
      |> join(:left, [u, ui1], ui2 in UserIp, on: ui1.ip == ui2.ip)
      |> where([u, _ui1, ui2], u.id != ^user.id and ui2.user_id == ^user.id)
      |> select([u, _ui1, _ui2], u)
      |> preload(:bans)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    fp_matches =
      User
      |> join(:inner, [u], _ in assoc(u, :user_fingerprints))
      |> join(:left, [u, uf1], uf2 in UserFingerprint, on: uf1.fingerprint == uf2.fingerprint)
      |> where([u, _uf1, uf2], u.id != ^user.id and uf2.user_id == ^user.id)
      |> select([u, _uf1, _uf2], u)
      |> preload(:bans)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    both_matches = Map.take(ip_matches, Map.keys(fp_matches))

    ip_matches = Map.drop(ip_matches, Map.keys(both_matches))

    fp_matches = Map.drop(fp_matches, Map.keys(both_matches))

    %AliasMatches{
      user: user,
      both_matches: Map.values(both_matches),
      ip_matches: Map.values(ip_matches),
      fp_matches: Map.values(fp_matches)
    }
  end

  defp update_profile_description(%User{} = user, attrs) do
    user
    |> User.description_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
    |> case do
      {:ok, user} ->
        if not Approval.approved?(user, user.description, :external_links) or
             not Approval.approved?(user, user.personal_title, :external_links) do
          Reports.create_system_report(
            "Review",
            "Profile contains external links",
            reported_user_id: user.id
          )
        end

        {:ok, user}

      error ->
        error
    end
  end

  defp update_profile_scratchpad(%User{} = user, attrs) do
    user
    |> User.scratchpad_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  defp persist_avatar(%User{} = user, attrs) do
    user
    |> Uploader.analyze_upload(attrs)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        Uploader.persist_upload(user)
        Uploader.unpersist_old_upload(user)

        reindex_user(user)

        {:ok, user}

      error ->
        error
    end
  end

  defp clear_avatar(%User{} = user) do
    user
    |> User.remove_avatar_changeset()
    |> Repo.update()
    |> case do
      {:ok, user} ->
        Uploader.unpersist_old_upload(user)

        reindex_user(user)

        {:ok, user}

      error ->
        error
    end
  end

  defp rename_user(user, user_params) do
    old_name = user.name

    account = User.name_changeset(user, user_params)

    Multi.new()
    |> UserNameChanges.record_rename(:name_change, user)
    |> Multi.update(:account, account)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: %{name: new_name} = account}} ->
        Exq.enqueue(Exq, "indexing", UserRenameWorker, [old_name, new_name])

        reindex_user(account)

        {:ok, account}

      {:error, :account, changeset, _changes} ->
        {:error, changeset}
    end
  end

  # Authentication-role hydration and restricted-forum cleanup.

  defp load_with_roles(query) do
    query
    |> Repo.one()
    |> Repo.preload([:roles, :current_filter, :settings])
    |> setup_roles()
  end

  defp setup_roles(nil), do: nil

  defp setup_roles(user) do
    role_map =
      user.roles
      |> Enum.group_by(& &1.resource_type, & &1.name)
      |> Map.new(fn {type, names} -> {type, Map.new(names, &{&1, []})} end)

    %{user | role_map: role_map}
  end

  defp unsubscribe_restricted_actors(%User{} = user) do
    forum_ids =
      Forum
      |> order_by(asc: :name)
      |> Repo.all()
      |> Enum.reject(&Canada.Can.can?(user, :show, &1))
      |> Enum.map(& &1.id)

    {_count, nil} =
      Forums.Subscription
      |> where([s], s.user_id == ^user.id and s.forum_id in ^forum_ids)
      |> Repo.delete_all()

    {_count, nil} =
      Topics.Subscription
      |> join(:inner, [s], _ in assoc(s, :topic))
      |> where([s, t], s.user_id == ^user.id and t.forum_id in ^forum_ids)
      |> Repo.delete_all()

    {:ok, nil}
  end

  # Shared after-commit indexing result handling.

  defp reindex_after_update(result) do
    case result do
      {:ok, user} ->
        reindex_user(user)

        {:ok, user}

      error ->
        error
    end
  end

  ## Authentication and user lookup

  @doc """
  Gets a user by API token.

  ## Examples

      iex> get_user_by_authentication_token("5Ow89k7nW24E0K34d3zX")
      %User{}

      iex> get_user_by_authentication_token("invalid")
      nil

  """
  @spec get_user_by_authentication_token(String.t()) :: User.t() | nil
  def get_user_by_authentication_token(token) when is_binary(token) do
    User
    |> Repo.get_by(authentication_token: token)
    |> Repo.preload(:settings)
  end

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by name.

  ## Examples

      iex> get_user_by_name("Administrator")
      %User{}

      iex> get_user_by_name("nonexistent")
      nil

  """
  @spec get_user_by_name(String.t()) :: User.t() | nil
  def get_user_by_name(name) when is_binary(name) do
    Repo.get_by(User, name: name)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password", &unlock_url/1)
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password", &unlock_url/1)
      nil

  """
  @spec get_user_by_email_and_password(String.t(), String.t(), (String.t() -> String.t())) ::
          User.t() | nil
  def get_user_by_email_and_password(email, password, unlock_url_fun)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)

    cond do
      is_nil(user) or not is_nil(user.locked_at) ->
        nil

      User.valid_password?(user, password) ->
        user
        |> User.successful_attempt_changeset()
        |> Repo.update!()
        |> reindex_user()

      true ->
        user
        |> User.failed_attempt_changeset()
        |> Repo.update!()
        |> reindex_user()
        |> maybe_send_unlock_instructions(unlock_url_fun)

        nil
    end
  end

  @doc """
  Loads the active profile named by integer `id` for `actor`, with public links
  and badge awards preloaded.

  Malformed, missing, and deactivated IDs are consistently not-found. A real
  active user the actor may not show is unauthorized.

  ## Examples

      iex> load_profile_by_id(actor, "1")
      {:ok, %User{}}

      iex> load_profile_by_id(actor, "not-an-id")
      {:error, :not_found}

  """
  @spec load_profile_by_id(Actor.t(), Loader.integer_id()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def load_profile_by_id(%Actor{} = actor, id) do
    User
    |> where([user], is_nil(user.deleted_at))
    |> Loader.fetch_and_authorize(actor, :show, id, public_links: :tag, awards: :badge)
  end

  @doc """
  Loads the visible, active profile named by `slug` for `actor`.

  Missing and deactivated profiles are always not found. A real active profile
  that the actor may not show is unauthorized.

  ## Examples

      iex> load_profile(actor, "somebody")
      {:ok, %User{}}

      iex> load_profile(actor, "missing")
      {:error, :not_found}

  """
  @spec load_profile(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def load_profile(%Actor{} = actor, slug) do
    User
    |> where([user], user.slug == ^slug and is_nil(user.deleted_at))
    |> Loader.one_and_authorize(actor, :show)
  end

  @doc """
  Loads an active user by exact name for an actor-scoped cross-context lookup.

  Conversations use this locator when resolving a recipient. Missing,
  malformed, and deactivated recipients are always not found; a real active
  user the actor may not show is unauthorized.

  ## Examples

      iex> load_active_user_by_name(actor, "Somebody")
      {:ok, %User{}}

      iex> load_active_user_by_name(actor, "missing")
      {:error, :not_found}

  """
  @spec load_active_user_by_name(Actor.t(), term()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def load_active_user_by_name(%Actor{} = actor, name) when is_binary(name) do
    User
    |> where([user], user.name == ^name and is_nil(user.deleted_at))
    |> Loader.one_and_authorize(actor, :show)
  end

  def load_active_user_by_name(%Actor{}, _name), do: {:error, :not_found}

  @doc """
  Loads a visible profile by slug as a report target on behalf of `actor`.

  Deactivated and missing profiles are always not-found. A real profile the
  actor may not show is unauthorized.

  ## Examples

      iex> load_report_target(actor, "somebody")
      {:ok, %User{}}
  """
  @spec load_report_target(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def load_report_target(%Actor{} = actor, slug) do
    with {:ok, user} <- load_profile(actor, slug) do
      {:ok, Repo.preload(user, public_links: :tag, awards: :badge)}
    end
  end

  @doc """
  Preloads a user's awards and their badges.

  Returns `nil` when given `nil`.

  ## Examples

      iex> preload_preview_awards(user)
      %User{awards: [%Award{badge: %Badge{}}]}

      iex> preload_preview_awards(nil)
      nil

  """
  @spec preload_preview_awards(User.t() | nil) :: User.t() | nil
  def preload_preview_awards(nil), do: nil
  def preload_preview_awards(%User{} = user), do: Repo.preload(user, awards: :badge)

  @doc """
  Returns the site staff grouped into categories, as a keyword list of
  `{category, [%User{}]}` in a fixed order.

  Staff are the users whose role is `"admin"`, `"moderator"`, or `"assistant"`,
  ordered by name. A staff member who hides their default role and carries no
  distinguishing secondary role matches no category and is omitted.

  ## Examples

      iex> staff_categories()
      [Administrators: [%User{}], "Technical Team": [], ...]

  """
  @spec staff_categories() :: keyword([User.t()])
  def staff_categories do
    users =
      User
      |> where([u], u.role in ["admin", "moderator", "assistant"])
      |> order_by(asc: :name)
      |> Repo.all()

    [
      Administrators: Enum.filter(users, &(&1.role == "admin" and &1.hide_default_role == false)),
      "Technical Team":
        Enum.filter(
          users,
          &(&1.role != "admin" and &1.secondary_role in ["Site Developer", "Devops"])
        ),
      "Public Relations":
        Enum.filter(users, &(&1.role != "admin" and &1.secondary_role == "Public Relations")),
      Moderators:
        Enum.filter(
          users,
          &(&1.role == "moderator" and &1.secondary_role in [nil, ""] and
              &1.hide_default_role == false)
        ),
      Assistants:
        Enum.filter(
          users,
          &(&1.role == "assistant" and &1.secondary_role in [nil, ""] and
              &1.hide_default_role == false)
        ),
      Others:
        Enum.filter(
          users,
          &(&1.role != "user" and
              &1.secondary_role not in [nil, "", "Site Developer", "Devops", "Public Relations"] and
              &1.hide_default_role == true)
        )
    ]
  end

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
    |> reindex_after_update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user_registration(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_registration(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  ## Settings

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_email(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_email(user, attrs \\ %{}) do
    User.email_changeset(user, attrs)
  end

  @doc """
  Emulates that the email will change without actually changing
  it in the database.

  ## Examples

      iex> apply_user_email(user, "valid password", %{email: ...})
      {:ok, %User{}}

      iex> apply_user_email(user, "invalid password", %{email: ...})
      {:error, %Ecto.Changeset{}}

  """
  @spec apply_user_email(User.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def apply_user_email(user, password, attrs) do
    user
    |> User.email_changeset(attrs)
    |> User.validate_current_password(password)
    |> Ecto.Changeset.apply_action(:update)
  end

  @doc """
  Updates the user email in token.

  If the token matches, the user email is updated and the token is deleted.
  The confirmed_at date is also updated to the current time.

  ## Examples

      iex> update_user_email(user, token)
      :ok

      iex> update_user_email(user, "invalid")
      :error

  """
  @spec update_user_email(User.t(), String.t()) :: :ok | :error
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
         %UserToken{sent_to: email} <- Repo.one(query),
         {:ok, _} <- Repo.transaction(user_email_multi(user, email, context)) do
      reindex_user(user)

      :ok
    else
      _ -> :error
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_update_email_instructions(user, current_email, &url(~p"/registrations/email/#{&1})")
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_update_email_instructions(
          User.t(),
          String.t(),
          (String.t() -> String.t())
        ) :: term()
  def deliver_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Unlocks the user by the given token.

  If the token matches, the user is marked as unlocked
  and the token is deleted.

  ## Examples

      iex> unlock_user_by_token(token)
      {:ok, %User{}}

      iex> unlock_user_by_token("invalid")
      :error

  """
  @spec unlock_user_by_token(String.t()) :: {:ok, User.t()} | :error
  def unlock_user_by_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "unlock"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(unlock_user_multi(user)) do
      reindex_user(user)

      {:ok, user}
    else
      _ -> :error
    end
  end

  @doc ~S"""
  Delivers the unlock instructions to the given user.

  ## Examples

    iex> deliver_user_unlock_instructions(user, &url(~p"/unlocks/#{&1}"))
    {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_unlock_instructions(User.t(), (String.t() -> String.t())) :: term()
  def deliver_user_unlock_instructions(%User{} = user, unlock_url_fun)
      when is_function(unlock_url_fun, 1) do
    if is_nil(user.locked_at) do
      {:error, :not_locked}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "unlock")
      Repo.insert!(user_token)
      UserNotifier.deliver_unlock_instructions(user, unlock_url_fun.(encoded_token))
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_password(User.t(), map()) :: Ecto.Changeset.t()
  def change_user_password(user, attrs \\ %{}) do
    User.password_changeset(user, attrs)
  end

  @doc """
  Updates the user password.

  ## Examples

      iex> update_user_password(user, "valid password", %{password: ...})
      {:ok, %User{}}

      iex> update_user_password(user, "invalid password", %{password: ...})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user_password(User.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_user_password(user, password, attrs) do
    changeset =
      user
      |> User.password_changeset(attrs)
      |> User.validate_current_password(password)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        reindex_user(user)

        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  ## Two-factor authentication

  @doc """
  Generates and stores a fresh TOTP secret for the user's account.

  The secret must exist before two-factor authentication can be confirmed. Does
  not reindex.

  ## Examples

      iex> setup_totp_secret(user)
      {:ok, %User{}}

  """
  @spec setup_totp_secret(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def setup_totp_secret(%User{} = user) do
    user
    |> User.create_totp_secret_changeset()
    |> Repo.update()
  end

  @doc """
  Enables or disables two-factor authentication for the user's account.

  Accepts `params` carrying the current password and second-factor token. When
  TOTP is off and both checks pass, it is enabled and a fresh set of backup
  codes is generated; when TOTP is on it is disabled. On success the user is
  reindexed.

  Returns `{:ok, user, backup_codes}` - the plaintext backup codes cannot be
  retrieved afterward and are always freshly generated, even when disabling -
  or `{:error, %Ecto.Changeset{}}` when the password or token is rejected.

  ## Examples

      iex> update_totp(user, %{"user" => %{"current_password" => "...", "twofactor_token" => "..."}})
      {:ok, %User{}, ["a1b2c3d4e5f6", ...]}

  """
  @spec update_totp(User.t(), map()) ::
          {:ok, User.t(), [String.t()]} | {:error, Ecto.Changeset.t()}
  def update_totp(%User{} = user, params) do
    backup_codes = User.random_backup_codes()

    user
    |> User.totp_changeset(params, backup_codes)
    |> Repo.update()
    |> case do
      {:ok, user} ->
        reindex_user(user)

        {:ok, user, backup_codes}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  ## Session

  @doc """
  Generates a session token.

  ## Examples

      iex> generate_user_session_token(user)
      "signed-token"

  """
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Generates a TOTP token.

  ## Examples

      iex> generate_user_totp_token(user)
      "signed-token"

  """
  @spec generate_user_totp_token(User.t()) :: binary()
  def generate_user_totp_token(user) do
    {token, user_token} = UserToken.build_totp_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Consumes a second-factor token for the given user during sign-in.

  Accepts the `params` (with the `"user"` / `"twofactor_token"`
  keys), validating the token against the user's TOTP secret or, failing that,
  its remaining backup codes. A matching TOTP code records the consumed timestep;
  a matching backup code removes it from the list.

  Returns `{:ok, user}` when the token is accepted, or
  `{:error, %Ecto.Changeset{}}` when it is not.

  ## Examples

      iex> consume_totp_token(user, %{"user" => %{"twofactor_token" => "123456"}})
      {:ok, %User{}}

  """
  @spec consume_totp_token(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def consume_totp_token(%User{} = user, params) do
    user
    |> User.consume_totp_token_changeset(params)
    |> Repo.update()
  end

  @doc """
  Gets the user with the given signed token.

  ## Examples

      iex> get_user_by_session_token(token)
      %User{}

      iex> get_user_by_session_token("invalid")
      nil

  """
  @spec get_user_by_session_token(binary()) :: User.t() | nil
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    load_with_roles(query)
  end

  @doc """
  Checks if a TOTP token is valid for a given user.

  Returns false if no user is provided.

  ## Examples

      iex> user_totp_token_valid?(user, "123456")
      true

      iex> user_totp_token_valid?(nil, "123456")
      false

  """
  @spec user_totp_token_valid?(User.t() | nil, binary()) :: boolean()
  def user_totp_token_valid?(nil, _token) do
    false
  end

  def user_totp_token_valid?(user, token) do
    {:ok, query} = UserToken.verify_totp_token_query(user, token)
    Repo.exists?(query)
  end

  @doc """
  Deletes the signed token with the given context.

  ## Examples

      iex> delete_session_token(token)
      :ok

  """
  @spec delete_session_token(binary()) :: :ok
  def delete_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Deletes the signed token with the given context.

  ## Examples

      iex> delete_totp_token(token)
      :ok

  """
  @spec delete_totp_token(binary()) :: :ok
  def delete_totp_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "totp"))
    :ok
  end

  ## Confirmation

  @doc ~S"""
  Delivers the confirmation email instructions to the given user.

  ## Examples

      iex> deliver_user_confirmation_instructions(user, &url(~p"/confirmations/#{&1}"))
      {:ok, %{to: ..., body: ...}}

      iex> deliver_user_confirmation_instructions(confirmed_user, &url(~p"/confirmations/#{&1}"))
      {:error, :already_confirmed}

  """
  @spec deliver_user_confirmation_instructions(User.t(), (String.t() -> String.t())) :: term()
  def deliver_user_confirmation_instructions(%User{} = user, confirmation_url_fun)
      when is_function(confirmation_url_fun, 1) do
    if user.confirmed_at do
      {:error, :already_confirmed}
    else
      {encoded_token, user_token} = UserToken.build_email_token(user, "confirm")
      Repo.insert!(user_token)
      UserNotifier.deliver_confirmation_instructions(user, confirmation_url_fun.(encoded_token))
    end
  end

  @doc """
  Confirms a user by the given token.

  If the token matches, the user account is marked as confirmed
  and the token is deleted.

  ## Examples

      iex> confirm_user(token)
      {:ok, %User{}}

      iex> confirm_user("invalid")
      :error

  """
  @spec confirm_user(String.t()) :: {:ok, User.t()} | :error
  def confirm_user(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <- Repo.transaction(confirm_user_multi(user)) do
      reindex_user(user)

      {:ok, user}
    else
      _ -> :error
    end
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/passwords/#{&1}/edit"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_reset_password_instructions(User.t(), (String.t() -> String.t())) :: term()
  def deliver_user_reset_password_instructions(%User{} = user, reset_password_url_fun)
      when is_function(reset_password_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(user_token)
    UserNotifier.deliver_reset_password_instructions(user, reset_password_url_fun.(encoded_token))
  end

  @doc ~S"""
  Delivers the reactivate account email to the given user.

  ## Examples

      iex> deliver_user_reactivation_instructions(user, &url(~p"/reactivations/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_reactivation_instructions(User.t(), (String.t() -> String.t())) :: term()
  def deliver_user_reactivation_instructions(%User{} = user, reactivation_url_fun)
      when is_function(reactivation_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "reactivate")
    Repo.insert!(user_token)
    UserNotifier.deliver_reactivation_instructions(user, reactivation_url_fun.(encoded_token))
  end

  @doc """
  Gets the user by reset password token.

  ## Examples

      iex> get_user_by_reset_password_token("validtoken")
      %User{}

      iex> get_user_by_reset_password_token("invalidtoken")
      nil

  """
  @spec get_user_by_reset_password_token(String.t()) :: User.t() | nil
  def get_user_by_reset_password_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Resets the user password.

  ## Examples

      iex> reset_user_password(user, %{password: "new long password", password_confirmation: "new long password"})
      {:ok, %User{}}

      iex> reset_user_password(user, %{password: "valid", password_confirmation: "not the same"})
      {:error, %Ecto.Changeset{}}

  """
  @spec reset_user_password(User.t(), map()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_user_password(user, attrs) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.password_changeset(user, attrs))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, :all))
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        reindex_user(user)

        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Returns the general settings changeset for a loaded user.

  ## Examples

      iex> settings_changeset(user)
      %Ecto.Changeset{}

  """
  @spec settings_changeset(User.t()) :: Ecto.Changeset.t()
  def settings_changeset(%User{} = user), do: change_user(user)

  @doc """
  Returns the filter-selection changeset for a loaded user.

  ## Examples

      iex> filter_selection_changeset(user)
      %Ecto.Changeset{}

  """
  @spec filter_selection_changeset(User.t()) :: Ecto.Changeset.t()
  def filter_selection_changeset(%User{} = user), do: change_user(user)

  @doc """
  Returns the TOTP form changeset for a loaded user.

  ## Examples

      iex> totp_changeset(user)
      %Ecto.Changeset{}

  """
  @spec totp_changeset(User.t()) :: Ecto.Changeset.t()
  def totp_changeset(%User{} = user), do: change_user(user)

  ## Administration

  @doc """
  Runs the staff user search on behalf of `viewer`, from `params` and
  `pagination`.

  Reading the user listing requires the user-index permission, so a viewer
  without it is `{:error, :unauthorized}`. The `"uq"` param supplies the query
  (blank or missing searches everything), and `"sf"`/`"sd"` select the sort
  field and direction from the user-domain fields.

  Returns `{:ok, users}` with a `m:Scrivener.Page` of matching users, or
  `{:error, message}` carrying the parser's message string when the query cannot
  be compiled.

  ## Examples

      iex> search_users(actor, %{"uq" => "name:somebody"}, pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_users(actor, %{"uq" => "("}, pagination)
      {:error, "..."}

  """
  @spec search_users(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized | String.t()}
  def search_users(%Actor{} = viewer, params, pagination) do
    with :ok <- authorize(viewer, :index, User) do
      query_string =
        case params["uq"] do
          nil -> "*"
          "" -> "*"
          query_string -> query_string
        end

      case Users.Query.compile(query_string) do
        {:ok, query} ->
          users =
            User
            |> Search.search_definition(
              %{query: query, sort: user_search_sort(params)},
              pagination
            )
            |> Search.search_records(User)

          {:ok, users}

        {:error, msg} ->
          {:error, msg}
      end
    end
  end

  @doc """
  Loads the user named by `slug` for editing, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are
  `{:error, :not_found}`; real targets are authorized for `:edit`.

  Returns a typed form containing the user, changeset, and assignable roles.

  ## Examples

      iex> load_user_for_edit(actor, "somebody")
      {:ok, %AdminUserForm{}}

      iex> load_user_for_edit(actor, "missing")
      {:error, :not_found}

  """
  @spec load_user_for_edit(Actor.t(), String.t()) ::
          {:ok, AdminUserForm.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_user_for_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_user_by_slug(actor, :edit, slug, [:roles]) do
      {:ok, admin_user_form(user)}
    end
  end

  @doc """
  Updates the details of the user named by `slug`, on behalf of `actor`, from
  `params`.

  Write access is checked before lookup. Missing targets are
  `{:error, :not_found}`; real targets are authorized for `:update`. On success
  the user is updated, reindexed, unsubscribed from any now-restricted forums,
  and a moderation log is written in the transaction.

  Returns `{:ok, user}`, or a typed admin form when validation rejects the
  update.

  ## Examples

      iex> update_user_details(actor, "somebody", %{"role" => "assistant"})
      {:ok, %User{}}

      iex> update_user_details(actor, "missing", %{})
      {:error, :not_found}

  """
  @spec update_user_details(Actor.t(), String.t(), map()) ::
          {:ok, User.t()}
          | {:error, :ban | :unauthorized | :not_found | AdminUserForm.t()}
  def update_user_details(%Actor{} = actor, slug, params) do
    with :ok <- verify_write_access(actor) do
      Repo.transact(fn ->
        with {:ok, user} <- load_user_by_slug(actor, :update, slug, [:roles]),
             {:ok, user} <- Repo.update(update_user_changeset(user, params)),
             {:ok, _} <- unsubscribe_restricted_actors(user),
             {:ok, _log} <-
               ModerationLogs.create_moderation_log(
                 actor,
                 "Admin.User:update",
                 Paths.profile_path(user),
                 "Updated user details for #{user.name}"
               ) do
          {:ok, user}
        end
      end)
      |> case do
        {:ok, %User{} = user} ->
          reindex_user(user)
          {:ok, user}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, admin_user_form(changeset.data, changeset)}

        error ->
          error
      end
    end
  end

  @doc """
  Reactivates the deactivated user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success the
  account is reactivated, reindexed, and a moderation log is written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_reactivate_user(actor, "somebody")
      {:ok, %User{}}

      iex> admin_reactivate_user(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_reactivate_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_reactivate_user(%Actor{} = actor, slug) do
    managed_user_transaction(
      actor,
      slug,
      :reactivate,
      fn user ->
        Repo.delete_all(UserToken.user_and_contexts_query(user, ["reactivate"]))
        Repo.update(User.reactivate_changeset(user))
      end,
      "Admin.User.Activation:create",
      &"Reactivated #{&1.name}"
    )
  end

  @doc """
  Deactivates the user named by `slug`, on behalf of `actor`, recording `actor`
  as the deactivator.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success the
  account is deactivated, reindexed, and a moderation log is written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_deactivate_user(actor, "somebody")
      {:ok, %User{}}

      iex> admin_deactivate_user(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_deactivate_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_deactivate_user(%Actor{} = actor, slug) do
    managed_user_transaction(
      actor,
      slug,
      :deactivate,
      &Repo.update(User.deactivate_changeset(&1, actor.user)),
      "Admin.User.Activation:delete",
      &"Deactivated #{&1.name}"
    )
  end

  @doc """
  Resets the API token of the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success a
  fresh token is generated, the account reindexed, and a moderation log is
  written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_reset_api_key(actor, "somebody")
      {:ok, %User{}}

      iex> admin_reset_api_key(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_reset_api_key(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_reset_api_key(%Actor{} = actor, slug) do
    managed_user_transaction(
      actor,
      slug,
      :reset_api_key,
      &Repo.update(User.api_key_changeset(&1)),
      "Admin.User.ApiKey:delete",
      &"Reset API key for #{&1.name}"
    )
  end

  @doc """
  Removes the avatar of the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success the
  avatar is cleared, the old file unpersisted, the account reindexed, and a
  moderation log is written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_remove_avatar(actor, "somebody")
      {:ok, %User{}}

      iex> admin_remove_avatar(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_remove_avatar(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_remove_avatar(%Actor{} = actor, slug) do
    with {:ok, user} <-
           managed_user_transaction(
             actor,
             slug,
             :remove_avatar,
             &Repo.update(User.remove_avatar_changeset(&1)),
             "Admin.User.Avatar:delete",
             &"Removed avatar for #{&1.name}"
           ) do
      Uploader.unpersist_old_upload(user)
      {:ok, user}
    end
  end

  @doc """
  Starts a downvote wipe for the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success a
  background job removes the user's downvotes and a moderation log is written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_wipe_downvotes(actor, "somebody")
      {:ok, %User{}}

      iex> admin_wipe_downvotes(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_wipe_downvotes(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_wipe_downvotes(%Actor{} = actor, slug) do
    with {:ok, user} <-
           logged_managed_user(
             actor,
             slug,
             :wipe_downvotes,
             "Admin.User.Downvote:delete",
             &"Wiped downvotes for #{&1.name}"
           ) do
      Exq.enqueue(Exq, "indexing", UserUnvoteWorker, [user.id, false])
      {:ok, user}
    end
  end

  @doc """
  Loads the user named by `slug` for erasure, on behalf of `actor`, applying the
  eligibility guards.

  Write access is checked before lookup. Missing targets are
  `{:error, :not_found}`; real targets are authorized with the `:erase` ability.
  Only ordinary, unverified accounts may be erased:

    * a privileged (non-`"user"` role) target is `{:error, {:privileged, user}}`;
    * a verified target is `{:error, {:verified, user}}`.

  Returns `{:ok, user}` for an erasable user, with its roles preloaded.

  ## Examples

      iex> load_user_for_erase(actor, "somebody")
      {:ok, %User{}}

      iex> load_user_for_erase(actor, "missing")
      {:error, :not_found}
  """
  @spec load_user_for_erase(Actor.t(), String.t()) ::
          {:ok, User.t()}
          | {:error,
             :ban | :unauthorized | :not_found | {:privileged, User.t()} | {:verified, User.t()}}
  def load_user_for_erase(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_user_by_slug(actor, :erase, slug, [:roles]) do
      cond do
        user.role != "user" -> {:error, {:privileged, user}}
        user.verified -> {:error, {:verified, user}}
        true -> {:ok, user}
      end
    end
  end

  @doc """
  Erases the user named by `slug`, on behalf of `actor`.

  The target is loaded and guarded following `load_user_for_erase/2`. On success
  the account is deactivated, renamed to a random handle, enqueued for the
  remaining data deletion, and a moderation log is written naming the original
  account.

  Returns `{:ok, user}` with the renamed account.

  ## Examples

      iex> admin_erase_user(actor, "somebody")
      {:ok, %User{name: "deactivated_..."}}

      iex> admin_erase_user(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_erase_user(Actor.t(), String.t()) ::
          {:ok, User.t()}
          | {:error,
             :ban | :unauthorized | :not_found | {:privileged, User.t()} | {:verified, User.t()}}
  def admin_erase_user(%Actor{} = actor, slug) do
    result =
      Repo.transact(fn ->
        with {:ok, user} <- load_user_for_erase(actor, slug) do
          original_name = user.name
          random_hex = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

          with {:ok, user} <- Repo.update(User.deactivate_changeset(user, actor.user)),
               {:ok, erased} <-
                 Repo.update(
                   update_user_changeset(user, %{"name" => "deactivated_#{random_hex}"})
                 ),
               {:ok, _log} <-
                 ModerationLogs.create_moderation_log(
                   actor,
                   "Admin.User.Erase:create",
                   Paths.profile_path(erased),
                   "Erased #{original_name}"
                 ) do
            {:ok, erased}
          end
        end
      end)

    with {:ok, erased} <- result do
      reindex_user(erased)
      Exq.enqueue(Exq, "indexing", UserEraseWorker, [erased.id, actor.user.id])
      {:ok, erased}
    end
  end

  @doc """
  Loads the user named by `slug` for forcing a filter, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability.

  Returns a typed form containing the user and force-filter changeset.

  ## Examples

      iex> load_user_for_force_filter(actor, "somebody")
      {:ok, %UserForm{}}

      iex> load_user_for_force_filter(actor, "missing")
      {:error, :not_found}

  """
  @spec load_user_for_force_filter(Actor.t(), String.t()) ::
          {:ok, UserForm.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_user_for_force_filter(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_user_by_slug(actor, :force_filter, slug) do
      {:ok, user_form(user)}
    end
  end

  @doc """
  Forces a filter on the user named by `slug`, on behalf of `actor`, from
  `params`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success the
  filter is forced, the account reindexed, and a moderation log is written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_force_filter(actor, "somebody", %{"forced_filter_id" => filter.id})
      {:ok, %User{}}

      iex> admin_force_filter(actor, "missing", %{})
      {:error, :not_found}

  """
  @spec admin_force_filter(Actor.t(), String.t(), map()) ::
          {:ok, User.t()}
          | {:error, :ban | :unauthorized | :not_found | UserForm.t()}
  def admin_force_filter(%Actor{} = actor, slug, params) do
    result =
      managed_user_transaction(
        actor,
        slug,
        :force_filter,
        &Repo.update(User.force_filter_changeset(&1, params)),
        "Admin.User.ForceFilter:create",
        &"Forced filter #{&1.forced_filter_id} for #{&1.name}"
      )

    case result do
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, user_form(changeset.data, changeset)}

      result ->
        result
    end
  end

  @doc """
  Removes the forced filter from the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success the
  forced filter is cleared, the account reindexed, and a moderation log is
  written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_unforce_filter(actor, "somebody")
      {:ok, %User{}}

      iex> admin_unforce_filter(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_unforce_filter(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_unforce_filter(%Actor{} = actor, slug) do
    managed_user_transaction(
      actor,
      slug,
      :unforce_filter,
      &Repo.update(User.unforce_filter_changeset(&1)),
      "Admin.User.ForceFilter:delete",
      &"Removed forced filter for #{&1.name}"
    )
  end

  @doc """
  Unlocks the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success the
  account is unlocked, reindexed, and a moderation log is written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_unlock_user(actor, "somebody")
      {:ok, %User{}}

      iex> admin_unlock_user(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_unlock_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_unlock_user(%Actor{} = actor, slug) do
    managed_user_transaction(
      actor,
      slug,
      :unlock,
      &Repo.update(User.unlock_changeset(&1)),
      "Admin.User.Unlock:create",
      &"Unlocked #{&1.name}"
    )
  end

  @doc """
  Grants verification to the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success
  verification is granted, the account reindexed, and a moderation log is
  written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_verify_user(actor, "somebody")
      {:ok, %User{}}

      iex> admin_verify_user(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_verify_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_verify_user(%Actor{} = actor, slug) do
    managed_user_transaction(
      actor,
      slug,
      :verify,
      &Repo.update(User.verify_changeset(&1)),
      "Admin.User.Verification:create",
      &"Granted verification to #{&1.name}"
    )
  end

  @doc """
  Revokes verification from the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success
  verification is revoked, the account reindexed, and a moderation log is
  written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_unverify_user(actor, "somebody")
      {:ok, %User{}}

      iex> admin_unverify_user(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_unverify_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_unverify_user(%Actor{} = actor, slug) do
    managed_user_transaction(
      actor,
      slug,
      :unverify,
      &Repo.update(User.unverify_changeset(&1)),
      "Admin.User.Verification:delete",
      &"Revoked verification from #{&1.name}"
    )
  end

  @doc """
  Starts a vote and fave wipe for the user named by `slug`, on behalf of
  `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success a
  background job removes the user's votes and favorites and a moderation log is
  written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_wipe_votes(actor, "somebody")
      {:ok, %User{}}

      iex> admin_wipe_votes(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_wipe_votes(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_wipe_votes(%Actor{} = actor, slug) do
    with {:ok, user} <-
           logged_managed_user(
             actor,
             slug,
             :wipe_votes,
             "Admin.User.Vote:delete",
             &"Wiped votes and faves for #{&1.name}"
           ) do
      Exq.enqueue(Exq, "indexing", UserUnvoteWorker, [user.id, true])
      {:ok, user}
    end
  end

  @doc """
  Queues a PII wipe for the user named by `slug`, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are `{:error, :not_found}`;
  real targets are authorized with the action-specific ability. On success a
  background job wipes the user's personally identifying information and a
  moderation log is written.

  Returns `{:ok, user}`.

  ## Examples

      iex> admin_wipe_user(actor, "somebody")
      {:ok, %User{}}

      iex> admin_wipe_user(actor, "missing")
      {:error, :not_found}

  """
  @spec admin_wipe_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def admin_wipe_user(%Actor{} = actor, slug) do
    with {:ok, user} <-
           logged_managed_user(
             actor,
             slug,
             :wipe,
             "Admin.User.Wipe:create",
             &"Wiped PII for #{&1.name}"
           ) do
      Exq.enqueue(Exq, "indexing", UserWipeWorker, [user.id])
      {:ok, user}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing a user's spoiler type.

  ## Examples

      iex> spoiler_type_changeset(user)
      %Ecto.Changeset{data: %Settings{}}

  """
  @spec spoiler_type_changeset(User.t()) :: Ecto.Changeset.t()
  def spoiler_type_changeset(%User{} = user) do
    Settings.spoiler_type_changeset(user.settings, %{})
  end

  @doc """
  Updates a user's spoiler type settings.

  ## Examples

      iex> update_spoiler_type(actor, %{spoiler_type: "click"})
      {:ok, %Settings{}}

      iex> update_spoiler_type(actor, %{spoiler_type: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_spoiler_type(Actor.t(), map()) ::
          {:ok, %Settings{}} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def update_spoiler_type(%Actor{user: %User{} = user} = actor, attrs) do
    with :ok <- verify_write_access(actor) do
      user.settings
      |> Settings.spoiler_type_changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Updates a user's general settings.

  ## Examples

      iex> update_settings(actor, %{"theme" => "dark"})
      {:ok, %User{}}

      iex> update_settings(actor, %{"theme" => bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_settings(Actor.t(), map()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def update_settings(%Actor{user: %User{} = user} = actor, attrs) do
    with :ok <- verify_write_access(actor) do
      user
      |> User.settings_changeset(attrs)
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Loads the user named by the profile `slug` for editing the description, on
  behalf of `actor`.

  Write access is checked before lookup. Missing targets are
  `{:error, :not_found}`; real targets are authorized for `:edit_description`.

  Returns a typed form containing the user and description changeset.

  ## Examples

      iex> load_profile_for_description_edit(actor, "somebody")
      {:ok, %UserForm{}}

      iex> load_profile_for_description_edit(actor, "missing")
      {:error, :not_found}

  """
  @spec load_profile_for_description_edit(Actor.t(), String.t()) ::
          {:ok, UserForm.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_profile_for_description_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_user_by_slug(actor, :edit_description, slug) do
      {:ok, user_form(user)}
    end
  end

  @doc """
  Updates the description and personal title of the user named by the profile
  `slug`, on behalf of `actor`, from `attrs`.

  This is a write, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. The user is then loaded by slug and authorized for
  `:edit_description` following `load_profile_for_description_edit/2`. On success
  the description and personal title are updated and the user reindexed; a
  profile that gains an unapproved external link files a system report.

  Returns `{:ok, user}`, or a typed user form when validation rejects the
  update.

  ## Examples

      iex> update_description(actor, "somebody", %{"description" => "About me"})
      {:ok, %User{}}

      iex> update_description(actor, "missing", %{})
      {:error, :not_found}

  """
  @spec update_description(Actor.t(), String.t(), map()) ::
          {:ok, User.t()}
          | {:error, :ban | :unauthorized | :not_found | UserForm.t()}
  def update_description(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_user_by_slug(actor, :edit_description, slug) do
      case update_profile_description(user, attrs) do
        {:ok, user} -> {:ok, user}
        {:error, changeset} -> {:error, user_form(user, changeset)}
      end
    end
  end

  @doc """
  Loads the potential aliases of the user named by the profile `slug`, on behalf
  of `actor`: other users who share one of the subject's IP addresses, one of
  its fingerprints, or both.

  Missing targets are `{:error, :not_found}`; real targets are authorized for
  `:show_details`.

  Returns a typed alias-match result with each match list carrying the matched
  users and their bans.

  ## Examples

      iex> load_alias_matches(actor, "somebody")
      {:ok, %AliasMatches{}}

      iex> load_alias_matches(actor, "missing")
      {:error, :not_found}

  """
  @spec load_alias_matches(Actor.t(), String.t()) ::
          {:ok, AliasMatches.t()} | {:error, :unauthorized | :not_found}
  def load_alias_matches(%Actor{} = actor, slug) do
    with {:ok, user} <- load_user_by_slug(actor, :show_details, slug) do
      {:ok, alias_matches(user)}
    end
  end

  @doc """
  Loads the user named by the profile `slug` for editing the moderation
  scratchpad, on behalf of `actor`.

  Write access is checked before lookup. Missing targets are
  `{:error, :not_found}`; real targets are authorized for `:edit_scratchpad`.

  Returns a typed form containing the user and scratchpad changeset.

  ## Examples

      iex> load_profile_for_scratchpad_edit(actor, "somebody")
      {:ok, %UserForm{}}

      iex> load_profile_for_scratchpad_edit(actor, "missing")
      {:error, :not_found}

  """
  @spec load_profile_for_scratchpad_edit(Actor.t(), String.t()) ::
          {:ok, UserForm.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_profile_for_scratchpad_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_user_by_slug(actor, :edit_scratchpad, slug) do
      {:ok, user_form(user)}
    end
  end

  @doc """
  Updates the moderation scratchpad of the user named by the profile `slug`, on
  behalf of `actor`, from `attrs`.

  This is a write, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. Editing the scratchpad requires the mod-note viewing
  permission, so an actor without it is `{:error, :unauthorized}`; a permitted
  actor naming an unknown slug is `{:error, :not_found}`. On success the
  scratchpad is updated and the user reindexed.

  Returns `{:ok, user}`, or a typed user form when validation rejects the
  update.

  ## Examples

      iex> update_scratchpad(actor, "somebody", %{"scratchpad" => "Staff note"})
      {:ok, %User{}}

      iex> update_scratchpad(actor, "missing", %{})
      {:error, :not_found}

  """
  @spec update_scratchpad(Actor.t(), String.t(), map()) ::
          {:ok, User.t()}
          | {:error, :ban | :unauthorized | :not_found | UserForm.t()}
  def update_scratchpad(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_user_by_slug(actor, :edit_scratchpad, slug) do
      case update_profile_scratchpad(user, attrs) do
        {:ok, user} -> {:ok, user}
        {:error, changeset} -> {:error, user_form(user, changeset)}
      end
    end
  end

  @doc """
  Adds a tag to a user's watched tags list.

  ## Examples

      iex> watch_tag(actor, tag)
      {:ok, %User{}}

  """
  @spec watch_tag(Actor.t(), Philomena.Tags.Tag.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def watch_tag(%Actor{user: %User{} = user} = actor, tag) do
    watched_tag_ids = Enum.uniq([tag.id | user.watched_tag_ids])

    with :ok <- verify_write_access(actor) do
      user
      |> User.watched_tags_changeset(watched_tag_ids)
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Removes a tag from a user's watched tags list.

  ## Examples

      iex> unwatch_tag(actor, tag)
      {:ok, %User{}}

  """
  @spec unwatch_tag(Actor.t(), Philomena.Tags.Tag.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def unwatch_tag(%Actor{user: %User{} = user} = actor, tag) do
    watched_tag_ids = user.watched_tag_ids -- [tag.id]

    with :ok <- verify_write_access(actor) do
      user
      |> User.watched_tags_changeset(watched_tag_ids)
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Loads the avatar changeset for the acting user's own account, on behalf of
  `actor`.

  Write access is checked first; otherwise returns a typed user form.

  ## Examples

      iex> load_user_for_avatar_edit(actor)
      {:ok, %UserForm{}}

      iex> load_user_for_avatar_edit(banned_actor)
      {:error, :ban}

  """
  @spec load_user_for_avatar_edit(Actor.t()) ::
          {:ok, UserForm.t()} | {:error, :ban | :unauthorized}
  def load_user_for_avatar_edit(%Actor{user: user} = actor) do
    with :ok <- verify_write_access(actor) do
      {:ok, user_form(user)}
    end
  end

  @doc """
  Updates the acting user's own avatar from `attrs`, on behalf of `actor`.

  This is a write, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. On success the uploaded file is analyzed, persisted,
  and the user reindexed.

  Returns `{:ok, user}`, or a typed user form when analysis or validation
  rejects the update.

  ## Examples

      iex> update_avatar(actor, %{"avatar" => upload})
      {:ok, %User{}}

      iex> update_avatar(banned_actor, %{"avatar" => upload})
      {:error, :ban}

  """
  @spec update_avatar(Actor.t(), map()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | UserForm.t()}
  def update_avatar(%Actor{user: user} = actor, attrs) do
    with :ok <- verify_write_access(actor) do
      case persist_avatar(user, attrs) do
        {:ok, user} -> {:ok, user}
        {:error, changeset} -> {:error, user_form(user, changeset)}
      end
    end
  end

  @doc """
  Removes the acting user's own avatar, on behalf of `actor`.

  This is a write, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`.

  Returns `{:ok, user}`.

  ## Examples

      iex> remove_avatar(actor)
      {:ok, %User{}}

      iex> remove_avatar(banned_actor)
      {:error, :ban}

  """
  @spec remove_avatar(Actor.t()) :: {:ok, User.t()} | {:error, :ban | :unauthorized}
  def remove_avatar(%Actor{user: user} = actor) do
    with :ok <- verify_write_access(actor) do
      clear_avatar(user)
    end
  end

  @doc """
  Loads the rename changeset for the acting user's own account, on behalf of
  `actor`.

  A banned actor is rejected first with `{:error, :ban}`. Renaming is authorized
  with `:change_username` against the actor's own user, which the ability rules
  gate on the 90-day rename window, so an actor who renamed within the window
  gets `{:error, :unauthorized}`.

  Returns a typed user form.

  ## Examples

      iex> load_user_for_rename(actor)
      {:ok, %UserForm{}}

      iex> load_user_for_rename(recently_renamed_actor)
      {:error, :unauthorized}

  """
  @spec load_user_for_rename(Actor.t()) ::
          {:ok, UserForm.t()} | {:error, :ban | :unauthorized}
  def load_user_for_rename(%Actor{user: user} = actor) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(user, :change_username, user) do
      {:ok, user_form(user)}
    end
  end

  @doc """
  Updates the acting user's own name from `user_params`, on behalf of `actor`,
  recording the change in history.

  This is a write, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. Renaming is then authorized with
  `:change_username` against the actor's own user (the ability rules gate it on
  the 90-day rename window). On success the old name becomes a name-change row,
  the account is reindexed, and a background job rewrites references to the old
  username.

  Returns `{:ok, user}`, or a typed user form when validation rejects the
  update.

  ## Examples

      iex> update_name(actor, %{"name" => "new_name"})
      {:ok, %User{}}

      iex> update_name(actor, %{"name" => ""})
      {:error, %UserForm{}}

  """
  @spec update_name(Actor.t(), map()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | UserForm.t()}
  def update_name(%Actor{user: user} = actor, user_params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(user, :change_username, user) do
      case rename_user(user, user_params) do
        {:ok, user} -> {:ok, user}
        {:error, changeset} -> {:error, user_form(user, changeset)}
      end
    end
  end

  @doc """
  Updates all search engine references to a user's old name with their new name.

  This is called as a background job after a user requests a name change.

  ## Examples

      iex> perform_rename("old_name", "new_name")
      :ok

  """
  @spec perform_rename(String.t(), String.t()) :: term()
  def perform_rename(old_name, new_name) do
    Images.user_name_reindex(old_name, new_name)
    Comments.user_name_reindex(old_name, new_name)
    Posts.user_name_reindex(old_name, new_name)
    Galleries.user_name_reindex(old_name, new_name)
    Reports.user_name_reindex(old_name, new_name)
    Filters.user_name_reindex(old_name, new_name)
    TagChanges.user_name_reindex(old_name, new_name)
    Users.user_name_reindex(old_name, new_name)
  end

  @doc """
  Deactivates the acting user's own account and sends a reactivation token.

  The database change commits before token delivery and indexing are queued.

  ## Examples

      iex> deactivate_account(actor, &reactivation_url/1)
      {:ok, %User{}}

      iex> deactivate_account(banned_actor, &reactivation_url/1)
      {:error, :ban}

  """
  @spec deactivate_account(Actor.t(), (String.t() -> String.t())) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def deactivate_account(%Actor{user: %User{} = user} = actor, reactivation_url_fun) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :deactivate_account, user),
         {:ok, user} <- Repo.update(User.deactivate_changeset(user, user)) do
      reindex_user(user)
      deliver_user_reactivation_instructions(user, reactivation_url_fun)
      {:ok, user}
    end
  end

  @doc """
  Reactivates an account by one-time email token.

  Invalid, expired, and already consumed tokens all return `:error` without
  revealing whether an account exists.

  ## Examples

      iex> reactivate_user_by_token(token)
      {:ok, %User{}}

      iex> reactivate_user_by_token("invalid")
      :error

  """
  @spec reactivate_user_by_token(String.t()) :: {:ok, User.t()} | :error
  def reactivate_user_by_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reactivate"),
         %User{} = user <- Repo.one(query),
         {:ok, %{user: user}} <-
           Repo.transaction(
             Multi.new()
             |> Multi.update(:user, User.reactivate_changeset(user))
             |> Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["reactivate"]))
           ) do
      reindex_user(user)
      {:ok, user}
    else
      _ -> :error
    end
  end

  @doc """
  Updates a user's current filter.

  ## Examples

      iex> set_current_filter(user, filter)
      {:ok, %User{}}

  """
  @spec set_current_filter(User.t(), Filter.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def set_current_filter(%User{} = user, %Filter{} = filter) do
    user
    |> User.filter_changeset(filter)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Clears a user's recent filter history.

  ## Examples

      iex> clear_recent_filters(actor)
      {:ok, %User{}}

  """
  @spec clear_recent_filters(Actor.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def clear_recent_filters(%Actor{user: %User{} = user} = actor) do
    with :ok <- verify_write_access(actor) do
      user
      |> User.clear_recent_filters_changeset()
      |> Repo.update()
      |> reindex_after_update()
    end
  end

  @doc """
  Clears an already loaded user's avatar during the trusted erase workflow.

  ## Examples

      iex> clear_avatar_for_erasure(user)
      {:ok, %User{}}

  """
  @spec clear_avatar_for_erasure(User.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def clear_avatar_for_erasure(%User{} = user), do: clear_avatar(user)

  @doc """
  Clears public profile text during the trusted erase workflow.

  ## Examples

      iex> clear_profile_for_erasure(user)
      {:ok, %User{}}

  """
  @spec clear_profile_for_erasure(User.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def clear_profile_for_erasure(%User{} = user) do
    update_profile_description(user, %{description: "", personal_title: ""})
  end

  @doc """
  Queues a single user for search index updates.
  Returns the user struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_user(user)
      %User{}

  """
  @spec reindex_user(User.t()) :: User.t()
  def reindex_user(%User{} = user) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Users", "id", [user.id]])

    user
  end

  @doc """
  Loads a user by trusted background-job ID.

  Job arguments originate from already persisted users, so an absent row is an
  invariant violation and intentionally raises.

  ## Examples

      iex> fetch_user_for_worker!(user.id)
      %User{}

  """
  @spec fetch_user_for_worker!(integer()) :: User.t()
  def fetch_user_for_worker!(id) when is_integer(id), do: Repo.get!(User, id)

  @doc """
  Returns the preload configuration for user indexing.

  Specifies which associations should be preloaded when indexing users,
  optimizing the queries for better performance.

  ## Examples

      iex> indexing_preloads()
      [deleted_by_user: query, bans: query, name_changes: query]

  """
  @spec indexing_preloads() :: keyword(Ecto.Query.t())
  def indexing_preloads do
    user_query = select(User, [u], map(u, [:name]))
    ban_query = select(Bans.User, [b], map(b, [:enabled, :valid_until]))
    name_change_query = select(UserNameChange, [n], map(n, [:name]))

    [
      deleted_by_user: user_query,
      bans: ban_query,
      name_changes: name_change_query
    ]
  end

  @doc """
  Performs a search reindex operation on users matching the given criteria.

  ## Parameters
  - column: The database column to filter on (e.g., :id)
  - condition: A list of values to match against the column

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      :ok

  """
  @spec perform_reindex(atom(), [term()]) :: term()
  def perform_reindex(column, condition) do
    User
    |> preload(^indexing_preloads())
    |> where([i], field(i, ^column) in ^condition)
    |> Search.reindex(User)
  end

  @doc """
  Updates user search indices when a user's name changes.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  @spec user_name_reindex(String.t(), String.t()) :: term()
  def user_name_reindex(old_name, new_name) do
    data = Users.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(User, data.query, data.set_replacements, data.replacements)
  end
end
