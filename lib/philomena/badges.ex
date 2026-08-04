defmodule Philomena.Badges do
  @moduledoc """
  Actor-scoped administration for badges and the awards attached to profiles.

  Badge and award writes enforce the global write prerequisite, authorize the
  action being performed, and commit their moderation log in the same database
  transaction. Profile award member routes are scoped by both profile slug and
  award ID, so an award can never be reached through another user's profile.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.Authorization
  alias Philomena.Badges.{Badge, Uploader}
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Repo
  alias Philomena.Users.User

  # Creates a badge.
  defp create_badge(attrs) do
    %Badge{}
    |> Badge.changeset(attrs)
    |> Uploader.analyze_upload(attrs)
    |> Repo.insert()
    |> case do
      {:ok, badge} ->
        Uploader.persist_upload(badge)
        Uploader.unpersist_old_upload(badge)

        {:ok, badge}

      error ->
        error
    end
  end

  # Updates a badge without updating its image.
  defp update_badge(%Badge{} = badge, attrs) do
    badge
    |> Badge.changeset(attrs)
    |> Repo.update()
  end

  # Updates the image for a badge.
  defp update_badge_image(%Badge{} = badge, attrs) do
    badge
    |> Badge.changeset(attrs)
    |> Uploader.analyze_upload(attrs)
    |> Repo.update()
    |> case do
      {:ok, badge} ->
        Uploader.persist_upload(badge)
        Uploader.unpersist_old_upload(badge)

        {:ok, badge}

      error ->
        error
    end
  end

  # Returns an `%Ecto.Changeset{}` for tracking badge changes.
  defp change_badge(%Badge{} = badge) do
    Badge.changeset(badge, %{})
  end

  defp load_badge(actor, action, id) do
    Loader.fetch_and_authorize(Badge, actor, action, id)
  end

  defp load_badge_change(actor, action, id) do
    with :ok <- verify_write_access(actor),
         {:ok, badge} <- load_badge(actor, action, id) do
      {:ok, {badge, change_badge(badge)}}
    end
  end

  defp transact_and_log(operation, log) do
    Repo.transact(fn ->
      with {:ok, result} <- operation.(),
           {:ok, _log} <- log.(result) do
        {:ok, result}
      end
    end)
  end

  @doc """
  Returns the paginated badges for the admin listing, on behalf of `actor`,
  ordered by title.

  ## Examples

      iex> load_badges(admin, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_badges(user, pagination)
      {:error, :unauthorized}

  """
  @spec load_badges(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_badges(%Actor{} = actor, pagination) do
    with :ok <- authorize(actor, :index, Badge) do
      badges =
        Badge
        |> order_by(asc: :title)
        |> Repo.paginate(pagination)

      {:ok, badges}
    end
  end

  @doc """
  Builds the changeset for creating a badge, on behalf of `actor`.

  ## Examples

      iex> new_badge(admin)
      {:ok, %Ecto.Changeset{}}

      iex> new_badge(user)
      {:error, :unauthorized}

  """
  @spec new_badge(Actor.t()) :: {:ok, Ecto.Changeset.t()} | Authorization.write_error()
  def new_badge(%Actor{} = actor) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, Badge) do
      {:ok, change_badge(%Badge{})}
    end
  end

  @doc """
  Creates a badge on behalf of `actor`, running the SVG upload pipeline.

  On success a moderation log attributing the creation to `actor` is written.

  ## Examples

      iex> create_badge(admin, badge_params)
      {:ok, %Badge{}}

      iex> create_badge(admin, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_badge(user, badge_params)
      {:error, :unauthorized}

  """
  @spec create_badge(Actor.t(), map()) ::
          {:ok, Badge.t()}
          | {:error, Authorization.write_error_reason() | Ecto.Changeset.t()}
  def create_badge(%Actor{} = actor, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Badge) do
      transact_and_log(fn -> create_badge(attrs) end, &badge_log(actor, :create, &1))
    end
  end

  @doc """
  Loads the badge named by `id` for editing, on behalf of `actor`, pairing it
  with a changeset for editing it.

  ## Examples

      iex> load_badge_for_edit(admin, badge_id)
      {:ok, {%Badge{}, %Ecto.Changeset{}}}

      iex> load_badge_for_edit(admin, invalid_id)
      {:error, :not_found}

      iex> load_badge_for_edit(user, badge_id)
      {:error, :unauthorized}

  """
  @spec load_badge_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Badge.t(), Ecto.Changeset.t()}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_badge_for_edit(%Actor{} = actor, id) do
    load_badge_change(actor, :edit, id)
  end

  @doc """
  Loads the badge named by `id` for the image edit form, on behalf of `actor`.
  The form authorizes the same `:update_image` action as its mutation.
  """
  @spec load_badge_for_image_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Badge.t(), Ecto.Changeset.t()}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_badge_for_image_edit(%Actor{} = actor, id) do
    load_badge_change(actor, :update_image, id)
  end

  @doc """
  Updates the badge named by `id` without touching its image, on behalf of
  `actor`.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_badge(admin, badge_id, badge_params)
      {:ok, %Badge{}}

      iex> update_badge(admin, badge_id, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_badge(admin, invalid_id, badge_params)
      {:error, :not_found}

      iex> update_badge(user, badge_id, badge_params)
      {:error, :unauthorized}

  """
  @spec update_badge(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Badge.t()}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def update_badge(%Actor{} = actor, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, badge} <- load_badge(actor, :update, id) do
      transact_and_log(fn -> update_badge(badge, attrs) end, &badge_log(actor, :update, &1))
    end
  end

  @doc """
  Updates the image of the badge named by `id`, on behalf of `actor`, running
  the SVG upload pipeline.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_badge_image(admin, badge_id, badge_params)
      {:ok, %Badge{}}

      iex> update_badge_image(admin, badge_id, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_badge_image(admin, invalid_id, badge_params)
      {:error, :not_found}

      iex> update_badge_image(user, badge_id, badge_params)
      {:error, :unauthorized}

  """
  @spec update_badge_image(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Badge.t()}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def update_badge_image(%Actor{} = actor, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, badge} <- load_badge(actor, :update_image, id) do
      transact_and_log(
        fn -> update_badge_image(badge, attrs) end,
        &badge_log(actor, :update_image, &1)
      )
    end
  end

  @doc """
  Loads the badge named by `id` together with the users who hold it, on behalf
  of `actor`, paginated and ordered by name.

  ## Examples

      iex> load_badge_users(admin, badge_id, pagination)
      {:ok, {%Badge{}, %Scrivener.Page{}}}

      iex> load_badge_users(admin, invalid_id, pagination)
      {:error, :not_found}

      iex> load_badge_users(user, badge_id, pagination)
      {:error, :unauthorized}

  """
  @spec load_badge_users(Actor.t(), Loader.integer_id(), Repo.pagination_params()) ::
          {:ok, {Badge.t(), Scrivener.Page.t()}} | {:error, :unauthorized | :not_found}
  def load_badge_users(%Actor{} = actor, id, pagination) do
    with {:ok, badge} <- load_badge(actor, :show_users, id) do
      users =
        User
        |> join(:inner, [u], _ in assoc(u, :awards))
        |> where([_u, a], a.badge_id == ^badge.id)
        |> order_by([u, _a], asc: u.name)
        |> Repo.paginate(pagination)

      {:ok, {badge, users}}
    end
  end

  @spec badge_log(Loader.actor(), atom(), Badge.t()) :: any()
  defp badge_log(actor, action, badge) do
    body =
      case action do
        :create -> "Created badge '#{badge.title}'"
        :update -> "Updated badge '#{badge.title}'"
        :update_image -> "Updated image of badge '#{badge.title}'"
      end

    type =
      case action do
        :update_image -> "Admin.Badge.Image:update"
        action -> "Admin.Badge:#{action}"
      end

    ModerationLogs.create_moderation_log(actor, type, "/admin/badges", body)
  end

  alias Philomena.Badges.Award

  defp create_badge_award(%Actor{user: creator}, user, attrs) do
    %Award{awarded_by_id: creator.id, user_id: user.id}
    |> Award.changeset(attrs)
    |> Repo.insert()
  end

  # Updates an award.
  defp update_badge_award(%Award{} = badge_award, attrs) do
    badge_award
    |> Award.changeset(attrs)
    |> Repo.update()
  end

  # Deletes an award.
  defp delete_badge_award(%Award{} = badge_award) do
    Repo.delete(badge_award)
  end

  # Returns an `%Ecto.Changeset{}` for tracking award changes.
  defp change_badge_award(%Award{} = badge_award) do
    Award.changeset(badge_award, %{})
  end

  defp awardable_badges do
    Badge
    |> where(disable_award: false)
    |> order_by(asc: :title)
    |> Repo.all()
  end

  defp award_profile_query(slug) do
    User
    |> where(slug: ^slug)
    |> where([user], is_nil(user.deleted_at))
  end

  defp load_award_profile(actor, action, slug) do
    with {:ok, user} <- Loader.one(award_profile_query(slug)),
         :ok <- authorize(actor, action, Award) do
      {:ok, user}
    end
  end

  defp scoped_award_query(slug, award_id) do
    Award
    |> join(:inner, [award], user in assoc(award, :user))
    |> where([award, user], award.id == ^award_id and user.slug == ^slug)
    |> where([_award, user], is_nil(user.deleted_at))
    |> preload([award, user], user: user)
    |> preload(:badge)
  end

  defp load_award(actor, action, slug, id) do
    case IntegerId.parse(id) do
      {:ok, award_id} ->
        with {:ok, award} <-
               Loader.one_and_authorize(scoped_award_query(slug, award_id), actor, action) do
          {:ok, {award.user, award}}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp present_award_create({:ok, award}, user), do: {:ok, {user, award}}

  defp present_award_create({:error, changeset}, user) do
    {:error, {user, changeset, awardable_badges()}}
  end

  defp present_award_update({:ok, award}, user, _original), do: {:ok, {user, award}}

  defp present_award_update({:error, changeset}, user, original) do
    {:error, {user, original, changeset, awardable_badges()}}
  end

  @doc """
  Loads the user named by the profile `slug` for creating an award, on behalf
  of `actor`.

  ## Examples

      iex> load_award_for_new(admin, user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}, [%Badge{}, ...]}}

      iex> load_award_for_new(admin, invalid_slug)
      {:error, :not_found}

      iex> load_award_for_new(user, user.slug)
      {:error, :unauthorized}

  """
  @spec load_award_for_new(Actor.t(), String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t(), [Badge.t()]}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_award_for_new(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_award_profile(actor, :new, slug) do
      {:ok, {user, change_badge_award(%Award{}), awardable_badges()}}
    end
  end

  @doc """
  Awards a badge to the user named by the profile `slug`, on behalf of `actor`,
  from `attrs`.

  On success a moderation log attributing the award to `actor` is written.
  Duplicate grants are allowed and create separate award records.

  ## Examples

      iex> award_badge(admin, user.slug, award_params)
      {:ok, {%User{}, %Award{}}}

      iex> award_badge(admin, user.slug, invalid_params)
      {:error, {%User{}, %Ecto.Changeset{}, [%Badge{}, ...]}}

      iex> award_badge(admin, invalid_slug, award_params)
      {:error, :not_found}

      iex> award_badge(user, user.slug, award_params)
      {:error, :unauthorized}

  """
  @spec award_badge(Actor.t(), String.t(), map()) ::
          {:ok, {User.t(), Award.t()}}
          | {:error, {User.t(), Ecto.Changeset.t(), [Badge.t()]}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def award_badge(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_award_profile(actor, :create, slug) do
      transact_and_log(
        fn -> create_badge_award(actor, user, attrs) end,
        &award_log(actor, :create, user, &1)
      )
      |> present_award_create(user)
    end
  end

  @doc """
  Loads the award named by `id` under the profile `slug` for editing, on behalf
  of `actor`.

  ## Examples

      iex> load_award_for_edit(admin, user.slug, award_id)
      {:ok, {%User{}, %Award{}, %Ecto.Changeset{}, [%Badge{}, ...]}}

      iex> load_award_for_edit(admin, invalid_slug, award_id)
      {:error, :not_found}

      iex> load_award_for_edit(admin, user.slug, invalid_id)
      {:error, :not_found}

      iex> load_award_for_edit(user, user.slug, award_id)
      {:error, :unauthorized}

  """
  @spec load_award_for_edit(Actor.t(), String.t(), Loader.integer_id()) ::
          {:ok, {User.t(), Award.t(), Ecto.Changeset.t(), [Badge.t()]}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_award_for_edit(%Actor{} = actor, slug, id) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, award}} <- load_award(actor, :edit, slug, id) do
      {:ok, {user, award, change_badge_award(award), awardable_badges()}}
    end
  end

  @doc """
  Updates the award named by `id` under the profile `slug`, on behalf of
  `actor`, from `attrs`.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_badge_award(admin, user.slug, award_id, award_params)
      {:ok, {%User{}, %Award{}}}

      iex> update_badge_award(admin, user.slug, award_id, invalid_params)
      {:error, {%User{}, %Award{}, %Ecto.Changeset{}, [%Badge{}, ...]}}

      iex> update_badge_award(admin, invalid_slug, award_id, award_params)
      {:error, :not_found}

      iex> update_badge_award(admin, user.slug, invalid_id, award_params)
      {:error, :not_found}

      iex> update_badge_award(user, user.slug, award_id, award_params)
      {:error, :unauthorized}

  """
  @spec update_badge_award(Actor.t(), String.t(), Loader.integer_id(), map()) ::
          {:ok, {User.t(), Award.t()}}
          | {:error, {User.t(), Award.t(), Ecto.Changeset.t(), [Badge.t()]}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def update_badge_award(%Actor{} = actor, slug, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, award}} <- load_award(actor, :update, slug, id) do
      transact_and_log(
        fn -> update_badge_award(award, attrs) end,
        &award_log(actor, :update, user, &1)
      )
      |> present_award_update(user, award)
    end
  end

  @doc """
  Revokes the award named by `id` under the profile `slug`, on behalf of
  `actor`.

  On success a moderation log attributing the removal to `actor` is written.

  ## Examples

      iex> revoke_badge_award(admin, user.slug, award_id)
      {:ok, {%User{}, %Award{}}}

      iex> revoke_badge_award(admin, invalid_slug, award_id)
      {:error, :not_found}

      iex> revoke_badge_award(admin, user.slug, invalid_id)
      {:error, :not_found}

      iex> revoke_badge_award(user, user.slug, award_id)
      {:error, :unauthorized}

  """
  @spec revoke_badge_award(Actor.t(), String.t(), Loader.integer_id()) ::
          {:ok, {User.t(), Award.t()}}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def revoke_badge_award(%Actor{} = actor, slug, id) do
    with :ok <- verify_write_access(actor),
         {:ok, {user, award}} <- load_award(actor, :delete, slug, id),
         {:ok, award} <-
           transact_and_log(
             fn -> delete_badge_award(award) end,
             &award_log(actor, :delete, user, &1)
           ) do
      {:ok, {user, award}}
    end
  end

  @spec award_log(Loader.actor(), atom(), User.t(), Award.t()) :: any()
  defp award_log(actor, action, user, award) do
    award = Repo.preload(award, [:badge])

    {type, body} =
      case action do
        :create ->
          {"Profile.Award:create", "Awarded badge '#{award.badge.title}' to #{user.name}"}

        :update ->
          {"Profile.Award:update",
           "Updated award of badge '#{award.badge.title}' on #{user.name}"}

        :delete ->
          {"Profile.Award:delete", "Removed badge '#{award.badge.title}' from #{user.name}"}
      end

    ModerationLogs.create_moderation_log(actor, type, Paths.profile_path(user), body)
  end
end
