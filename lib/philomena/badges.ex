defmodule Philomena.Badges do
  @moduledoc """
  The Badges context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.IntegerId
  alias Philomena.Users.User
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Badges.Badge
  alias Philomena.Badges.Uploader

  @doc """
  Returns the list of badges.

  ## Examples

      iex> list_badges()
      [%Badge{}, ...]

  """
  def list_badges do
    Repo.all(Badge)
  end

  @doc """
  Gets a single badge.

  Raises `Ecto.NoResultsError` if the Badge does not exist.

  ## Examples

      iex> get_badge!(123)
      %Badge{}

      iex> get_badge!(456)
      ** (Ecto.NoResultsError)

  """
  def get_badge!(id), do: Repo.get!(Badge, id)

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

  @doc """
  Creates a badge.

  ## Examples

      iex> create_badge(%{field: value})
      {:ok, %Badge{}}

      iex> create_badge(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_badge(attrs \\ %{}) do
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

  @doc """
  Updates a badge without updating its image.

  ## Examples

      iex> update_badge(badge, %{field: new_value})
      {:ok, %Badge{}}

      iex> update_badge(badge, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_badge(%Badge{} = badge, attrs) do
    badge
    |> Badge.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the image for a badge.

  ## Examples

      iex> update_badge_image(badge, %{image: new_value})
      {:ok, %Badge{}}

      iex> update_badge_image(badge, %{image: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_badge_image(%Badge{} = badge, attrs) do
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

  @doc """
  Deletes a Badge.

  ## Examples

      iex> delete_badge(badge)
      {:ok, %Badge{}}

      iex> delete_badge(badge)
      {:error, %Ecto.Changeset{}}

  """
  def delete_badge(%Badge{} = badge) do
    Repo.delete(badge)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking badge changes.

  ## Examples

      iex> change_badge(badge)
      %Ecto.Changeset{source: %Badge{}}

  """
  def change_badge(%Badge{} = badge) do
    Badge.changeset(badge, %{})
  end

  alias Philomena.Badges.Award

  @doc """
  Returns the list of badge_awards.

  ## Examples

      iex> list_badge_awards()
      [%Award{}, ...]

  """
  def list_badge_awards do
    Repo.all(Award)
  end

  @doc """
  Gets a single badge_award.

  Raises `Ecto.NoResultsError` if the Badge award does not exist.

  ## Examples

      iex> get_badge_award!(123)
      %Award{}

      iex> get_badge_award!(456)
      ** (Ecto.NoResultsError)

  """
  def get_badge_award!(id), do: Repo.get!(Award, id)

  @doc """
  Gets a the badge_award with the given badge type belonging to the user.

  Raises nil if the Badge award does not exist.

  ## Examples

      iex> get_badge_award_for(badge, user)
      %Award{}

      iex> get_badge_award_for(badge, user)
      nil

  """
  def get_badge_award_for(badge, user) do
    Repo.get_by(Award, badge_id: badge.id, user_id: user.id)
  end

  @doc """
  Creates a badge_award.

  ## Examples

      iex> create_badge_award(%{field: value})
      {:ok, %Award{}}

      iex> create_badge_award(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_badge_award(creator, user, attrs \\ %{}) do
    %Award{awarded_by_id: creator.id, user_id: user.id}
    |> Award.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a badge_award.

  ## Examples

      iex> update_badge_award(badge_award, %{field: new_value})
      {:ok, %Award{}}

      iex> update_badge_award(badge_award, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_badge_award(%Award{} = badge_award, attrs) do
    badge_award
    |> Award.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Award.

  ## Examples

      iex> delete_badge_award(badge_award)
      {:ok, %Award{}}

      iex> delete_badge_award(badge_award)
      {:error, %Ecto.Changeset{}}

  """
  def delete_badge_award(%Award{} = badge_award) do
    Repo.delete(badge_award)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking badge_award changes.

  ## Examples

      iex> change_badge_award(badge_award)
      %Ecto.Changeset{source: %Award{}}

  """
  def change_badge_award(%Award{} = badge_award) do
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
  Loads the user named by the profile `slug` for the new award form, on behalf
  of `actor`.

  Awarding requires the `:create` badge-award permission, so an actor without it
  is `{:error, :unauthorized}`; a permitted actor naming an unknown slug is
  `{:error, :not_found}`.

  Returns `{:ok, {user, changeset}}`.
  """
  @spec load_award_for_new(User.t() | nil, String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_award_for_new(actor, slug) do
    with {:ok, user} <- load_award_profile(actor, slug) do
      {:ok, {user, change_badge_award(%Award{})}}
    end
  end

  @doc """
  Awards a badge to the user named by the profile `slug`, on behalf of `actor`,
  from the controller-shaped `attrs`.

  Awarding requires the `:create` badge-award permission, so an actor without it
  is `{:error, :unauthorized}`; a permitted actor naming an unknown slug is
  `{:error, :not_found}`. On success a moderation log attributing the award to
  `actor` is written.

  Returns `{:ok, {user, award}}` on success, or `{:error, {user, changeset}}`
  when the insert is rejected.
  """
  @spec award_badge(User.t() | nil, String.t(), map()) ::
          {:ok, {User.t(), Award.t()}}
          | {:error, {User.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def award_badge(actor, slug, attrs) do
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

  Awarding requires the `:create` badge-award permission, so an actor without it
  is `{:error, :unauthorized}`. A non-castable or unknown award id, and (for a
  permitted actor) an unknown slug, are `{:error, :not_found}`.

  Returns `{:ok, {user, award, changeset}}`.
  """
  @spec load_award_for_edit(User.t() | nil, String.t(), String.t()) ::
          {:ok, {User.t(), Award.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def load_award_for_edit(actor, slug, id) do
    with {:ok, {user, award}} <- load_award(actor, slug, id) do
      {:ok, {user, award, change_badge_award(award)}}
    end
  end

  @doc """
  Updates the award named by `id` under the profile `slug`, on behalf of
  `actor`, from the controller-shaped `attrs`.

  Awarding requires the `:create` badge-award permission, so an actor without it
  is `{:error, :unauthorized}`. A non-castable or unknown award id, and (for a
  permitted actor) an unknown slug, are `{:error, :not_found}`. On success a
  moderation log attributing the change to `actor` is written.

  Returns `{:ok, {user, award}}` on success, or
  `{:error, {user, award, changeset}}` when the update is rejected.
  """
  @spec update_badge_award(User.t() | nil, String.t(), String.t(), map()) ::
          {:ok, {User.t(), Award.t()}}
          | {:error, {User.t(), Award.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def update_badge_award(actor, slug, id, attrs) do
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

  Awarding requires the `:create` badge-award permission, so an actor without it
  is `{:error, :unauthorized}`. A non-castable or unknown award id, and (for a
  permitted actor) an unknown slug, are `{:error, :not_found}`. On success a
  moderation log attributing the removal to `actor` is written.

  Returns `{:ok, {user, award}}`.
  """
  @spec revoke_badge_award(User.t() | nil, String.t(), String.t()) ::
          {:ok, {User.t(), Award.t()}} | {:error, :unauthorized | :not_found}
  def revoke_badge_award(actor, slug, id) do
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
  # id. The award is loaded independently of the profile user, mirroring the two
  # separate lookups the award routes have always done.
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
