defmodule Philomena.ModerationLogs do
  @moduledoc """
  Append-only audit records for staff actions.

  Moderated database changes should compose `put_log/6` into their owning
  `Ecto.Multi`, so failure to persist the audit record rolls the action back.
  The actor-scoped listing exposes only the retained two-week window.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Ecto.Multi

  alias Philomena.Attribution.Actor
  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Repo
  alias Philomena.Users.User

  defp log_changeset(%User{} = user, type, subject_path, body) do
    %ModerationLog{user_id: user.id}
    |> ModerationLog.changeset(%{type: type, subject_path: subject_path, body: body})
  end

  defp list_moderation_logs(pagination) do
    ModerationLog
    |> where([ml], ml.created_at >= ago(2, "week"))
    |> preload(:user)
    |> order_by(desc: :created_at, desc: :id)
    |> Repo.paginate(pagination)
  end

  @doc """
  Returns the retained, paginated moderation logs visible to `actor`.

  Only records from the last two weeks are returned, newest first. Access is
  authorized with `:index` on `ModerationLog`.

  ## Examples

      iex> load_moderation_logs(admin, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_moderation_logs(user, pagination)
      {:error, :unauthorized}

  """
  @spec load_moderation_logs(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(ModerationLog.t())} | {:error, :unauthorized}
  def load_moderation_logs(%Actor{} = actor, pagination) do
    with :ok <- authorize(actor, :index, ModerationLog) do
      {:ok, list_moderation_logs(pagination)}
    end
  end

  @doc """
  Adds an attributed audit-log insert to `multi` under `step`.

  The returned `Ecto.Multi` does no work until its owner transacts it. A failed
  log changeset therefore rolls back every preceding database step. Build
  `subject_path` with `Philomena.ModerationLogs.Paths` when a canonical helper
  exists.

  ## Examples

      iex> put_log(multi, :log, actor, "User:update", "/profiles/name", "Updated user")
      %Ecto.Multi{}

  """
  @spec put_log(Multi.t(), Multi.name(), Actor.t(), String.t(), String.t(), String.t()) ::
          Multi.t()
  def put_log(%Multi{} = multi, step, %Actor{user: %User{} = user}, type, subject_path, body) do
    Multi.insert(multi, step, log_changeset(user, type, subject_path, body))
  end

  @doc """
  Immediately inserts an audit record for a legacy or non-transactional action.

  New transactional mutations should use `put_log/6`. This compatibility
  service remains while later context waves move existing post-hoc log calls
  into their owning `Ecto.Multi` transactions.

  ## Examples

      iex> create_moderation_log(actor, "User:update", "/profiles/name", "Updated user")
      {:ok, %ModerationLog{}}

  """
  @spec create_moderation_log(Actor.t() | User.t(), String.t(), String.t(), String.t()) ::
          {:ok, ModerationLog.t()} | {:error, Ecto.Changeset.t()}
  def create_moderation_log(actor, type, subject_path, body)

  def create_moderation_log(%Actor{} = actor, type, subject_path, body) do
    create_moderation_log(actor.user, type, subject_path, body)
  end

  def create_moderation_log(%User{} = user, type, subject_path, body) do
    user
    |> log_changeset(type, subject_path, body)
    |> Repo.insert()
  end

  @doc """
  Removes moderation logs older than the two-week retention window.

  This operational release task raises on database failure.

  ## Examples

      iex> cleanup!()
      {31, nil}

  """
  def cleanup! do
    ModerationLog
    |> where([ml], ml.created_at < ago(2, "week"))
    |> Repo.delete_all()
  end
end
