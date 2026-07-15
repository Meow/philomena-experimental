defmodule Philomena.Badges do
  @moduledoc """
  The Badges context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Attribution.Actor
  alias Philomena.IntegerId
  alias Philomena.Users.User
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Badges.Badge
  alias Philomena.Badges.Uploader

  @doc """
  Gets a single badge by its title.

  Returns nil if the Badge does not exist.

  ## Examples

      iex> get_badge_by_title("Artist")
      %Badge{}

      iex> get_badge_by_title("Nonexistent")
      nil

  """
  def get_badge_by_title(title), do: Repo.get_by(Badge, title: title)

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
  @spec new_badge(Actor.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_badge(%Actor{} = actor) do
    with :ok <- authorize(actor, :index, Badge) do
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
          {:ok, Badge.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_badge(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :index, Badge),
         {:ok, badge} <- create_badge(attrs) do
      badge_log(actor, :create, badge)
      {:ok, badge}
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
          {:ok, {Badge.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_badge_for_edit(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :index, Badge),
         {:ok, badge} <- fetch_badge(id) do
      {:ok, {badge, change_badge(badge)}}
    end
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
          {:ok, Badge.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_badge(%Actor{} = actor, id, attrs) do
    with :ok <- authorize(actor, :index, Badge),
         {:ok, badge} <- fetch_badge(id),
         {:ok, badge} <- update_badge(badge, attrs) do
      badge_log(actor, :update, badge)
      {:ok, badge}
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
          {:ok, Badge.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_badge_image(%Actor{} = actor, id, attrs) do
    with :ok <- authorize(actor, :index, Badge),
         {:ok, badge} <- fetch_badge(id),
         {:ok, badge} <- update_badge_image(badge, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Admin.Badge.Image:update",
        "/admin/badges",
        "Updated image of badge '#{badge.title}'"
      )

      {:ok, badge}
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
    with :ok <- authorize(actor, :index, Badge),
         {:ok, badge} <- fetch_badge(id) do
      users =
        User
        |> join(:inner, [u], _ in assoc(u, :awards))
        |> where([_u, a], a.badge_id == ^badge.id)
        |> order_by([u, _a], asc: u.name)
        |> Repo.paginate(pagination)

      {:ok, {badge, users}}
    end
  end

  @spec fetch_badge(Loader.integer_id()) :: Loader.fetch_result(Badge.t())
  defp fetch_badge(id) do
    Loader.fetch(Badge, id)
  end

  @spec badge_log(Loader.actor(), atom(), Badge.t()) :: any()
  defp badge_log(actor, action, badge) do
    body =
      case action do
        :create -> "Created badge '#{badge.title}'"
        :update -> "Updated badge '#{badge.title}'"
      end

    ModerationLogs.create_moderation_log(actor, "Admin.Badge:#{action}", "/admin/badges", body)
  end

  alias Philomena.Badges.Award

  @doc """
  Gets the award with the given badge type belonging to the given user.

  ## Examples

      iex> get_badge_award_for(badge, user)
      %Award{}

      iex> get_badge_award_for(badge, user)
      nil

  """
  @spec get_badge_award_for(Badge.t(), User.t()) :: Award.t() | nil
  def get_badge_award_for(badge, user) do
    Repo.get_by(Award, badge_id: badge.id, user_id: user.id)
  end

  # Creates an award.
  @doc false
  def create_badge_award(creator, user, attrs \\ %{})

  def create_badge_award(%User{} = creator, user, attrs) do
    %Award{awarded_by_id: creator.id, user_id: user.id}
    |> Award.changeset(attrs)
    |> Repo.insert()
  end

  def create_badge_award(%Actor{} = actor, user, attrs) do
    create_badge_award(actor.user, user, attrs)
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

  @doc """
  Lists the badges that may currently be awarded, ordered by title.

  ## Examples

      iex> awardable_badges()
      [%Badge{}, ...]

  """
  @spec awardable_badges() :: [Badge.t()]
  def awardable_badges do
    Badge
    |> where(disable_award: false)
    |> order_by(asc: :title)
    |> Repo.all()
  end

  @doc """
  Loads the user named by the profile `slug` for creating an award, on behalf
  of `actor`.

  ## Examples

      iex> load_award_for_new(admin, user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_award_for_new(admin, invalid_slug)
      {:error, :not_found}

      iex> load_award_for_new(user, user.slug)
      {:error, :unauthorized}

  """
  @spec load_award_for_new(Actor.t(), String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_award_for_new(%Actor{} = actor, slug) do
    with {:ok, user} <- load_award_profile(actor, slug) do
      {:ok, {user, change_badge_award(%Award{})}}
    end
  end

  @doc """
  Awards a badge to the user named by the profile `slug`, on behalf of `actor`,
  from `attrs`.

  On success a moderation log attributing the award to `actor` is written.

  ## Examples

      iex> award_badge(admin, user.slug, award_params)
      {:ok, {%User{}, %Award{}}}

      iex> award_badge(admin, user.slug, invalid_params)
      {:error, {%User{}, %Ecto.Changeset{}}}

      iex> award_badge(admin, invalid_slug, award_params)
      {:error, :not_found}

      iex> award_badge(user, user.slug, award_params)
      {:error, :unauthorized}

  """
  @spec award_badge(Actor.t(), String.t(), map()) ::
          {:ok, {User.t(), Award.t()}}
          | {:error, {User.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def award_badge(%Actor{} = actor, slug, attrs) do
    with {:ok, user} <- load_award_profile(actor, slug) do
      case create_badge_award(actor, user, attrs) do
        {:ok, award} ->
          award_log(actor, :create, user, award)
          {:ok, {user, award}}

        {:error, changeset} ->
          {:error, {user, changeset}}
      end
    end
  end

  @doc """
  Loads the award named by `id` under the profile `slug` for editing, on behalf
  of `actor`.

  ## Examples

      iex> load_award_for_edit(admin, user.slug, award_id)
      {:ok, {%User{}, %Award{}, %Ecto.Changeset{}}}

      iex> load_award_for_edit(admin, invalid_slug, award_id)
      {:error, :not_found}

      iex> load_award_for_edit(admin, user.slug, invalid_id)
      {:error, :not_found}

      iex> load_award_for_edit(user, user.slug, award_id)
      {:error, :unauthorized}

  """
  @spec load_award_for_edit(Actor.t(), String.t(), Loader.integer_id()) ::
          {:ok, {User.t(), Award.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def load_award_for_edit(%Actor{} = actor, slug, id) do
    with {:ok, {user, award}} <- load_award(actor, slug, id) do
      {:ok, {user, award, change_badge_award(award)}}
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
      {:error, {%User{}, %Award{}, %Ecto.Changeset{}}}

      iex> update_badge_award(admin, invalid_slug, award_id, award_params)
      {:error, :not_found}

      iex> update_badge_award(admin, user.slug, invalid_id, award_params)
      {:error, :not_found}

      iex> update_badge_award(user, user.slug, award_id, award_params)
      {:error, :unauthorized}

  """
  @spec update_badge_award(Actor.t(), String.t(), Loader.integer_id(), map()) ::
          {:ok, {User.t(), Award.t()}}
          | {:error, {User.t(), Award.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def update_badge_award(%Actor{} = actor, slug, id, attrs) do
    with {:ok, {user, award}} <- load_award(actor, slug, id) do
      case update_badge_award(award, attrs) do
        {:ok, award} ->
          award_log(actor, :update, user, award)
          {:ok, {user, award}}

        {:error, changeset} ->
          {:error, {user, award, changeset}}
      end
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
          {:ok, {User.t(), Award.t()}} | {:error, :unauthorized | :not_found}
  def revoke_badge_award(%Actor{} = actor, slug, id) do
    with {:ok, {user, award}} <- load_award(actor, slug, id) do
      {:ok, award} = delete_badge_award(award)
      award_log(actor, :delete, user, award)
      {:ok, {user, award}}
    end
  end

  # Authorizes `actor` to award badges and loads the profile user by slug.
  defp load_award_profile(actor, slug) do
    with :ok <- authorize(actor, :create, Award),
         %User{} = user <- Repo.get_by(User, slug: slug) do
      {:ok, user}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  # Authorizes `actor`, loads the profile user by slug, and loads the award by
  # id. The award is loaded independently of the profile user.
  defp load_award(actor, slug, id) do
    with {:ok, user} <- load_award_profile(actor, slug),
         {:ok, award_id} <- IntegerId.parse(id),
         %Award{} = award <- Repo.get(Award, award_id) do
      {:ok, {user, award}}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      # Unknown slug, non-castable award id, or unknown award id.
      shape when shape in [{:error, :not_found}, :error, nil] -> {:error, :not_found}
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
