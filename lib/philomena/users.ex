defmodule Philomena.Users do
  @moduledoc """
  The Users context.
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
  alias Philomena.Users.{User, UserToken, UserNotifier, Uploader, Settings}
  alias Philomena.{Forums, Forums.Forum}
  alias Philomena.Bans
  alias Philomena.Topics
  alias Philomena.Roles.Role
  alias Philomena.ModNotes.ModNote
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

  ## Database getters

  @doc """
  Gets a user by API token.

  ## Examples

      iex> get_user_by_authentication_token("5Ow89k7nW24E0K34d3zX")
      %User{}

      iex> get_user_by_authentication_token("invalid")
      nil

  """
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
  def get_user_by_name(name) when is_binary(name) do
    Repo.get_by(User, name: name)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
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

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Loads the user named by `id`, with their public links and badge awards
  preloaded.

  An unknown or deactivated user is `{:error, :not_found}`.

  Returns `{:ok, user}` or `{:error, :not_found}`.

  ## Examples

      iex> load_profile("1")
      {:ok, %User{}}

      iex> load_profile("999999999")
      {:error, :not_found}

  """
  @spec load_profile(any()) :: {:ok, User.t()} | {:error, :not_found}
  def load_profile(id) do
    # The id is interpolated without casting, so a non-integer id raises
    # Ecto.Query.CastError.
    user =
      User
      |> where(id: ^id)
      |> preload(public_links: :tag, awards: :badge)
      |> Repo.one()

    if is_nil(user) or user.deleted_at do
      {:error, :not_found}
    else
      {:ok, user}
    end
  end

  @doc """
  Preloads a user's awards and their badges.

  Returns `nil` when given `nil`.

  ## Examples

      iex> preload_awards(user)
      %User{awards: [%Award{badge: %Badge{}}]}

      iex> preload_awards(nil)
      nil

  """
  @spec preload_awards(User.t() | nil) :: User.t() | nil
  def preload_awards(nil), do: nil
  def preload_awards(%User{} = user), do: Repo.preload(user, awards: :badge)

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
  """
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

  defp user_email_multi(user, email, context) do
    changeset = user |> User.email_changeset(%{email: email}) |> User.confirm_changeset()

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, [context]))
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_update_email_instructions(user, current_email, &url(~p"/registrations/email/#{&1})")
      {:ok, %{to: ..., body: ...}}

  """
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
  """
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

  defp unlock_user_multi(user) do
    changeset = User.unlock_changeset(user)

    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, changeset)
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["unlock"]))
  end

  @doc """
  Unconditionally unlocks the given user.

  ## Examples

      iex> unlock_user(user)
      {:ok, %User{}}

  """
  def unlock_user(user) do
    user
    |> User.unlock_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc ~S"""
  Delivers the unlock instructions to the given user.

  ## Examples

    iex> deliver_user_unlock_instructions(user, &url(~p"/unlocks/#{&1}"))
    {:ok, %{to: ..., body: ...}}

  """
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

  Accepts the `params` carrying the current password and second-factor token. When TOTP is off and the password and token check out it
  is enabled and a fresh set of backup codes is generated; when TOTP is on it is
  disabled. On success the user is reindexed.

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
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Generates a TOTP token.
  """
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
  """
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
  def user_totp_token_valid?(nil, _token) do
    false
  end

  def user_totp_token_valid?(user, token) do
    {:ok, query} = UserToken.verify_totp_token_query(user, token)
    Repo.exists?(query)
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_session_token(token) do
    Repo.delete_all(UserToken.token_and_context_query(token, "session"))
    :ok
  end

  @doc """
  Deletes the signed token with the given context.
  """
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
  """
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

  defp confirm_user_multi(user) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:user, User.confirm_changeset(user))
    |> Ecto.Multi.delete_all(:tokens, UserToken.user_and_contexts_query(user, ["confirm"]))
  end

  ## Reset password

  @doc ~S"""
  Delivers the reset password email to the given user.

  ## Examples

      iex> deliver_user_reset_password_instructions(user, &url(~p"/passwords/#{&1}/edit"))
      {:ok, %{to: ..., body: ...}}

  """
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
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    changeset = update_user_changeset(user, attrs)

    Multi.new()
    |> Multi.update(:user, changeset)
    |> Multi.run(:unsubscribe, fn _repo, %{user: user} ->
      unsubscribe_restricted_actors(user)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{user: user}} ->
        reindex_user(user)

        {:ok, user}

      {:error, :user, changeset, _} ->
        {:error, changeset}
    end
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

  ## Administration

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

  @doc """
  Returns every assignable role.

  ## Examples

      iex> list_roles()
      [%Role{}, ...]

  """
  @spec list_roles() :: [Role.t()]
  def list_roles do
    Repo.all(Role)
  end

  @doc """
  Loads the user named by `slug` for editing, on behalf of `actor`.

  The user is loaded by slug and authorized for `:edit`; an unknown slug
  authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for actors whose grants
  cover `nil`). The returned user has its roles preloaded.

  Returns `{:ok, user}`.
  """
  @spec load_user_for_edit(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def load_user_for_edit(%Actor{} = actor, slug) do
    target = user_by_slug_with_roles(slug)

    with :ok <- authorize(actor, :edit, target),
         %User{} = user <- target do
      {:ok, user}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Updates the details of the user named by `slug`, on behalf of `actor`, from
  `params`.

  The user is loaded by slug and authorized for `:update`; an unknown slug
  authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for actors whose grants
  cover `nil`). On success the user is updated, reindexed, unsubscribed from any
  now-restricted forums, and a moderation log is written.

  Returns `{:ok, user}`, or `{:error, %Ecto.Changeset{}}` when the update is
  rejected.
  """
  @spec update_user_details(Actor.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_user_details(%Actor{} = actor, slug, params) do
    target = user_by_slug_with_roles(slug)

    with :ok <- authorize(actor, :update, target),
         %User{} = user <- target,
         {:ok, user} <- update_user(user, params) do
      log_managed_user(actor, user, "Admin.User:update", "Updated user details for #{user.name}")

      {:ok, user}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc """
  Reactivates the deactivated user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success the account is reactivated, reindexed, and
  a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_reactivate_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_reactivate_user(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = reactivate_user(user)
      log_managed_user(actor, user, "Admin.User.Activation:create", "Reactivated #{user.name}")

      {:ok, user}
    end
  end

  @doc """
  Deactivates the user named by `slug`, on behalf of `actor`, recording `actor`
  as the deactivator.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success the account is deactivated, reindexed, and
  a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_deactivate_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_deactivate_user(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = deactivate_user(actor.user, user)
      log_managed_user(actor, user, "Admin.User.Activation:delete", "Deactivated #{user.name}")

      {:ok, user}
    end
  end

  @doc """
  Resets the API token of the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success a fresh token is generated, the account
  reindexed, and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_reset_api_key(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_reset_api_key(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = reset_api_key(user)
      log_managed_user(actor, user, "Admin.User.ApiKey:delete", "Reset API key for #{user.name}")

      {:ok, user}
    end
  end

  @doc """
  Removes the avatar of the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success the avatar is cleared, the old file
  unpersisted, the account reindexed, and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_remove_avatar(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_remove_avatar(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = remove_avatar(user)
      log_managed_user(actor, user, "Admin.User.Avatar:delete", "Removed avatar for #{user.name}")

      {:ok, user}
    end
  end

  @doc """
  Starts a downvote wipe for the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success a background job to remove the user's
  downvotes is enqueued and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_wipe_downvotes(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_wipe_downvotes(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      Exq.enqueue(Exq, "indexing", UserUnvoteWorker, [user.id, false])

      log_managed_user(
        actor,
        user,
        "Admin.User.Downvote:delete",
        "Wiped downvotes for #{user.name}"
      )

      {:ok, user}
    end
  end

  @doc """
  Loads the user named by `slug` for erasure, on behalf of `actor`, applying the
  eligibility guards.

  Managing a user requires the user-edit permission, so an actor without it is
  `{:error, :unauthorized}`. Only ordinary, unverified accounts may be erased:

    * a slug naming no user is `{:error, :not_erasable}`;
    * a privileged (non-`"user"` role) target is `{:error, {:privileged, user}}`;
    * a verified target is `{:error, {:verified, user}}`.

  Returns `{:ok, user}` for an erasable user, with its roles preloaded.
  """
  @spec load_user_for_erase(Actor.t(), String.t()) ::
          {:ok, User.t()}
          | {:error,
             :unauthorized | :not_erasable | {:privileged, User.t()} | {:verified, User.t()}}
  def load_user_for_erase(%Actor{} = actor, slug) do
    with :ok <- authorize(actor, :edit, %User{}) do
      user = user_by_slug_with_roles(slug)

      cond do
        is_nil(user) -> {:error, :not_erasable}
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
  """
  @spec admin_erase_user(Actor.t(), String.t()) ::
          {:ok, User.t()}
          | {:error,
             :unauthorized | :not_erasable | {:privileged, User.t()} | {:verified, User.t()}}
  def admin_erase_user(%Actor{} = actor, slug) do
    with {:ok, user} <- load_user_for_erase(actor, slug),
         {:ok, erased} <- erase_user(user, actor.user) do
      log_managed_user(actor, erased, "Admin.User.Erase:create", "Erased #{user.name}")

      {:ok, erased}
    end
  end

  @doc """
  Loads the user named by `slug` for forcing a filter, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`.

  Returns `{:ok, user}`.
  """
  @spec load_user_for_force_filter(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def load_user_for_force_filter(%Actor{} = actor, slug) do
    load_managed_user(actor, slug)
  end

  @doc """
  Forces a filter on the user named by `slug`, on behalf of `actor`, from
  `params`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success the filter is forced, the account
  reindexed, and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_force_filter(Actor.t(), String.t(), map()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_force_filter(%Actor{} = actor, slug, params) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      # A `forced_filter_id` naming no filter fails the foreign-key constraint;
      # the raise on that mismatch is pinned.
      {:ok, user} = force_filter(user, params)

      log_managed_user(
        actor,
        user,
        "Admin.User.ForceFilter:create",
        "Forced filter #{user.forced_filter_id} for #{user.name}"
      )

      {:ok, user}
    end
  end

  @doc """
  Removes the forced filter from the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success the forced filter is cleared, the account
  reindexed, and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_unforce_filter(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_unforce_filter(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = unforce_filter(user)

      log_managed_user(
        actor,
        user,
        "Admin.User.ForceFilter:delete",
        "Removed forced filter for #{user.name}"
      )

      {:ok, user}
    end
  end

  @doc """
  Unlocks the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success the account is unlocked, reindexed, and a
  moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_unlock_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_unlock_user(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = unlock_user(user)
      log_managed_user(actor, user, "Admin.User.Unlock:create", "Unlocked #{user.name}")

      {:ok, user}
    end
  end

  @doc """
  Grants verification to the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success verification is granted, the account
  reindexed, and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_verify_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_verify_user(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = verify_user(user)

      log_managed_user(
        actor,
        user,
        "Admin.User.Verification:create",
        "Granted verification to #{user.name}"
      )

      {:ok, user}
    end
  end

  @doc """
  Revokes verification from the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success verification is revoked, the account
  reindexed, and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_unverify_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_unverify_user(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      {:ok, user} = unverify_user(user)

      log_managed_user(
        actor,
        user,
        "Admin.User.Verification:delete",
        "Revoked verification from #{user.name}"
      )

      {:ok, user}
    end
  end

  @doc """
  Starts a vote and fave wipe for the user named by `slug`, on behalf of
  `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success a background job to remove the user's votes
  and faves is enqueued and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_wipe_votes(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_wipe_votes(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      Exq.enqueue(Exq, "indexing", UserUnvoteWorker, [user.id, true])

      log_managed_user(
        actor,
        user,
        "Admin.User.Vote:delete",
        "Wiped votes and faves for #{user.name}"
      )

      {:ok, user}
    end
  end

  @doc """
  Queues a PII wipe for the user named by `slug`, on behalf of `actor`.

  Managing a user requires the user-edit permission, so an actor without it is
  rejected before the target is loaded; a well-formed slug naming no user is
  `{:error, :not_found}`. On success a background job to wipe the user's
  personally identifying information is enqueued and a moderation log is written.

  Returns `{:ok, user}`.
  """
  @spec admin_wipe_user(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
  def admin_wipe_user(%Actor{} = actor, slug) do
    with {:ok, user} <- load_managed_user(actor, slug) do
      Exq.enqueue(Exq, "indexing", UserWipeWorker, [user.id])
      log_managed_user(actor, user, "Admin.User.Wipe:create", "Wiped PII for #{user.name}")

      {:ok, user}
    end
  end

  defp user_by_slug_with_roles(slug) do
    User
    |> Repo.get_by(slug: slug)
    |> Repo.preload([:roles])
  end

  # Authorizes `actor` for `:edit` against the user schema, matching the gate
  # shared by the staff user-management actions, then loads the target by slug. An
  # unauthorized actor is rejected before the load; a well-formed slug naming no
  # row is `{:error, :not_found}`.
  defp load_managed_user(actor, slug) do
    with :ok <- authorize(actor, :edit, %User{}),
         %User{} = user <- Repo.get_by(User, slug: slug) do
      {:ok, user}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  defp log_managed_user(actor, user, type, body) do
    ModerationLogs.create_moderation_log(actor, type, Paths.profile_path(user), body)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing a user's spoiler type.

  ## Examples

      iex> change_spoiler_type(user)
      %Ecto.Changeset{data: %Settings{}}

  """
  def change_spoiler_type(%User{} = user) do
    Settings.spoiler_type_changeset(user.settings, %{})
  end

  @doc """
  Updates a user's spoiler type settings.

  ## Examples

      iex> update_spoiler_type(user, %{spoiler_type: "click"})
      {:ok, %Settings{}}

      iex> update_spoiler_type(user, %{spoiler_type: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_spoiler_type(%User{} = user, attrs) do
    user.settings
    |> Settings.spoiler_type_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a user's general settings.

  ## Examples

      iex> update_settings(user, %{"theme" => "dark"})
      {:ok, %User{}}

      iex> update_settings(user, %{"theme" => bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_settings(%User{} = user, attrs) do
    user
    |> User.settings_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Loads the user named by the profile `slug` for editing the description, on
  behalf of `actor`.

  A banned actor is rejected first with `{:error, :ban}`. The user is then
  loaded by slug and authorized for `:edit_description`; an unknown slug
  authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for viewers whose grants
  cover `nil`).

  Returns `{:ok, user}`.
  """
  @spec load_profile_for_description_edit(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_profile_for_description_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor) do
      load_authorized_profile(actor.user, :edit_description, slug)
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

  Returns `{:ok, user}`, or `{:error, %Ecto.Changeset{}}` when the update is
  rejected.
  """
  @spec update_description(Actor.t(), String.t(), map()) ::
          {:ok, User.t()}
          | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_description(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_authorized_profile(actor.user, :edit_description, slug) do
      update_description(user, attrs)
    end
  end

  # Loads a user by profile slug and authorizes the acting user for `action`
  # against the loaded record. An unknown slug authorizes a `nil` record, so an
  # actor whose grants do not cover `nil` gets `{:error, :unauthorized}` and one
  # who is permitted to act on `nil` gets `{:error, :not_found}`.
  defp load_authorized_profile(user, action, slug) do
    target = Repo.get_by(User, slug: slug)

    with :ok <- authorize(user, action, target),
         %User{} <- target do
      {:ok, target}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Loads the potential aliases of the user named by the profile `slug`, on behalf
  of `actor`: other users who share one of the subject's IP addresses, one of
  its fingerprints, or both.

  The subject is loaded by slug and authorized for `:show_details`; an unknown
  slug authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for viewers whose grants
  cover `nil`).

  Returns `{:ok, %{user: user, both_matches: [...], ip_matches: [...],
  fp_matches: [...]}}` with each match list carrying the matched users and their
  bans.
  """
  @spec load_alias_matches(Actor.t(), String.t()) ::
          {:ok, map()} | {:error, :unauthorized | :not_found}
  def load_alias_matches(%Actor{} = actor, slug) do
    user = Repo.get_by(User, slug: slug)

    with :ok <- authorize(actor, :show_details, user),
         %User{} <- user do
      {:ok, alias_matches(user)}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

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

    %{
      user: user,
      both_matches: Map.values(both_matches),
      ip_matches: Map.values(ip_matches),
      fp_matches: Map.values(fp_matches)
    }
  end

  @doc """
  Updates a user's profile description and personal title.

  ## Examples

      iex> update_description(user, %{"description" => "Hello world"})
      {:ok, %User{}}

      iex> update_description(user, %{"personal_title" => "Site Admin"})
      {:error, %Ecto.Changeset{}}

  """
  def update_description(%User{} = user, attrs) do
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

  @doc """
  Loads the user named by the profile `slug` for editing the moderation
  scratchpad, on behalf of `actor`.

  A banned actor is rejected first with `{:error, :ban}`. Editing the scratchpad
  requires the mod-note viewing permission, so an actor without it is
  `{:error, :unauthorized}`; a permitted actor naming an unknown slug is
  `{:error, :not_found}`.

  Returns `{:ok, user}`.
  """
  @spec load_profile_for_scratchpad_edit(Actor.t(), String.t()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | :not_found}
  def load_profile_for_scratchpad_edit(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor.user, :index, ModNote),
         %User{} = user <- Repo.get_by(User, slug: slug) do
      {:ok, user}
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
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

  Returns `{:ok, user}`, or `{:error, %Ecto.Changeset{}}` when the update is
  rejected.
  """
  @spec update_scratchpad(Actor.t(), String.t(), map()) ::
          {:ok, User.t()}
          | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_scratchpad(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor.user, :index, ModNote),
         %User{} = user <- Repo.get_by(User, slug: slug) do
      update_scratchpad(user, attrs)
    else
      {:error, _} = error -> error
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Updates a user's moderation scratchpad content.

  ## Examples

      iex> update_scratchpad(user, %{"scratchpad" => "My notes"})
      {:ok, %User{}}

  """
  def update_scratchpad(%User{} = user, attrs) do
    user
    |> User.scratchpad_changeset(attrs)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Adds a tag to a user's watched tags list.

  ## Examples

      iex> watch_tag(user, tag)
      {:ok, %User{}}

  """
  def watch_tag(%User{} = user, tag) do
    watched_tag_ids = Enum.uniq([tag.id | user.watched_tag_ids])

    user
    |> User.watched_tags_changeset(watched_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Removes a tag from a user's watched tags list.

  ## Examples

      iex> unwatch_tag(user, tag)
      {:ok, %User{}}

  """
  def unwatch_tag(%User{} = user, tag) do
    watched_tag_ids = user.watched_tag_ids -- [tag.id]

    user
    |> User.watched_tags_changeset(watched_tag_ids)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Loads the avatar changeset for the acting user's own account, on behalf of
  `actor`.

  A banned actor is rejected with `{:error, :ban}`; otherwise returns
  `{:ok, %Ecto.Changeset{}}`.
  """
  @spec load_user_for_avatar_edit(Actor.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized}
  def load_user_for_avatar_edit(%Actor{user: user} = actor) do
    with :ok <- verify_write_access(actor) do
      {:ok, change_user(user)}
    end
  end

  @doc """
  Updates the acting user's own avatar from `attrs`, on behalf of `actor`.

  This is a write, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`. On success the uploaded file is analyzed, persisted,
  and the user reindexed.

  Given a `%User{}` instead, updates that user's avatar directly with no
  write-access check, handling file analysis and persistence.

  Returns `{:ok, user}`, or `{:error, %Ecto.Changeset{}}` when analysis or the
  update is rejected.
  """
  @spec update_avatar(Actor.t(), map()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  @spec update_avatar(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_avatar(%Actor{user: user} = actor, attrs) do
    with :ok <- verify_write_access(actor) do
      update_avatar(user, attrs)
    end
  end

  def update_avatar(%User{} = user, attrs) do
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

  @doc """
  Removes the acting user's own avatar, on behalf of `actor`.

  This is a write, so the actor's write access is verified first: a banned
  actor is `{:error, :ban}` and an actor with no fingerprint
  `{:error, :unauthorized}`.

  Given a `%User{}` instead, removes that user's avatar directly with no
  write-access check.

  Returns `{:ok, user}`.
  """
  @spec remove_avatar(Actor.t()) :: {:ok, User.t()} | {:error, :ban | :unauthorized}
  @spec remove_avatar(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def remove_avatar(%Actor{user: user} = actor) do
    with :ok <- verify_write_access(actor) do
      remove_avatar(user)
    end
  end

  def remove_avatar(%User{} = user) do
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

  @doc """
  Loads the rename changeset for the acting user's own account, on behalf of
  `actor`.

  A banned actor is rejected first with `{:error, :ban}`. Renaming is authorized
  with `:change_username` against the actor's own user, which the ability rules
  gate on the 90-day rename window, so an actor who renamed within the window
  gets `{:error, :unauthorized}`.

  Returns `{:ok, %Ecto.Changeset{}}`.
  """
  @spec load_user_for_rename(Actor.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized}
  def load_user_for_rename(%Actor{user: user} = actor) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(user, :change_username, user) do
      {:ok, change_user(user)}
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

  Returns `{:ok, user}`, or `{:error, %Ecto.Changeset{}}` when the update is
  rejected.
  """
  @spec update_name(Actor.t(), map()) ::
          {:ok, User.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def update_name(%Actor{user: user} = actor, user_params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(user, :change_username, user) do
      rename_user(user, user_params)
    end
  end

  @doc """
  Updates a user's name and records the change in history.

  Triggers a background job to update references to the old username.

  ## Examples

      iex> rename_user(user, %{"name" => "new_name"})
      {:ok, %User{}}

  """
  @spec rename_user(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def rename_user(user, user_params) do
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

  @doc """
  Updates all search engine references to a user's old name with their new name.

  This is called as a background job after a user requests a name change.

  ## Examples

      iex> perform_rename("old_name", "new_name")
      :ok

  """
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
  Reactivates a previously deactivated user account. Removes all "reactivate" user tokens for that user if they exist.

  ## Examples

      iex> reactivate_user(user)
      {:ok, %User{}}

  """
  def reactivate_user(%User{} = user) do
    UserToken.user_and_contexts_query(user, ["reactivate"]) |> Repo.delete_all()

    user
    |> User.reactivate_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Deactivates a user account.

  Takes a moderator who is recorded as performing the deactivation.

  ## Examples

      iex> deactivate_user(moderator, user)
      {:ok, %User{}}

  """
  def deactivate_user(moderator, %User{} = user) do
    user
    |> User.deactivate_changeset(moderator)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Deactivates a user account with the user recorded performing the deactivation.

  ## Examples

      iex> deactivate_user(user)
      {:ok, %User{}}

  """
  def deactivate_user(%User{} = user) do
    user
    |> User.deactivate_changeset(user)
    |> Repo.update()
  end

  @doc """
  Gets the user by reactivation token.

  ## Examples

      iex> get_user_by_reactivation_token("validtoken")
      %User{}

      iex> get_user_by_reactivation_token("invalidtoken")
      nil

  """
  def get_user_by_reactivation_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reactivate"),
         %User{} = user <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Generates a new API key for the user.

  ## Examples

      iex> reset_api_key(user)
      {:ok, %User{}}

  """
  def reset_api_key(%User{} = user) do
    user
    |> User.api_key_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Updates a user's current filter.

  ## Examples

      iex> update_filter(user, filter)
      {:ok, %User{}}

  """
  def update_filter(%User{} = user, %Filter{} = filter) do
    user
    |> User.filter_changeset(filter)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Forces a specific filter on a user's account, which will be applied in
  conjunction to the user's current filter.

  ## Examples

      iex> force_filter(user, %{"forced_filter_id" => 123})
      {:ok, %User{}}

      iex> force_filter(user, %{"forced_filter_id" => bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def force_filter(%User{} = user, user_params) do
    user
    |> User.force_filter_changeset(user_params)
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Removes a forced filter from a user's account.

  ## Examples

      iex> unforce_filter(user)
      {:ok, %User{}}

  """
  def unforce_filter(%User{} = user) do
    user
    |> User.unforce_filter_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Clears a user's recent filter history.

  ## Examples

      iex> clear_recent_filters(user)
      {:ok, %User{}}

  """
  def clear_recent_filters(%User{} = user) do
    user
    |> User.clear_recent_filters_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  defp load_with_roles(query) do
    query
    |> Repo.one()
    |> Repo.preload([:roles, :current_filter, :settings])
    |> setup_roles()
  end

  @doc """
  Marks a user as verified for the purposes of automatically approving uploads,
  and posting images in comments/posts/messages without moderator review.

  ## Examples

      iex> verify_user(user)
      {:ok, %User{}}

  """
  def verify_user(%User{} = user) do
    user
    |> User.verify_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Unverifies a user, removing the automatic approval status.

  ## Examples

      iex> unverify_user(user)
      {:ok, %User{}}

  """
  def unverify_user(%User{} = user) do
    user
    |> User.unverify_changeset()
    |> Repo.update()
    |> reindex_after_update()
  end

  @doc """
  Erases all changes associated with a user account, removing all personal
  data and anonymizing the account.

  This is primarily intended for use with spam accounts or other situations
  where all of a user's data should be removed from the system.

  ## Examples

      iex> erase_user(user, moderator)
      {:ok, %User{}}

  """
  def erase_user(%User{} = user, %User{} = moderator) do
    # Deactivate to prevent the user from racing these changes
    {:ok, user} = deactivate_user(moderator, user)

    # Rename to prevent usage for brand recognition SEO
    random_hex = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    {:ok, user} = update_user(user, %{name: "deactivated_#{random_hex}"})

    # Enqueue a background job to perform the rest of the deletion
    Exq.enqueue(Exq, "indexing", UserEraseWorker, [user.id, moderator.id])

    {:ok, user}
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

  @doc """
  Queues a single user for search index updates.
  Returns the user struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_user(user)
      %User{}

  """
  def reindex_user(%User{} = user) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Users", "id", [user.id]])

    user
  end

  @doc """
  Returns the preload configuration for user indexing.

  Specifies which associations should be preloaded when indexing users,
  optimizing the queries for better performance.

  ## Examples

      iex> indexing_preloads()
      [deleted_by_user: query, bans: query, name_changes: query]

  """
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
  def perform_reindex(column, condition) do
    User
    |> preload(^indexing_preloads())
    |> where([i], field(i, ^column) in ^condition)
    |> Search.reindex(User)
  end

  defp reindex_after_update(result) do
    case result do
      {:ok, user} ->
        reindex_user(user)

        {:ok, user}

      error ->
        error
    end
  end

  @doc """
  Updates user search indices when a user's name changes.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  def user_name_reindex(old_name, new_name) do
    data = Users.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(User, data.query, data.set_replacements, data.replacements)
  end
end
