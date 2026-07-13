defmodule Philomena.ModerationLogs do
  @moduledoc """
  The ModerationLogs context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.ModerationLogs.ModerationLog
  alias Philomena.Users.User

  @doc """
  Returns the paginated moderation logs for `user` (the current viewer).

  The log is staff-only. Returns `{:error, :unauthorized}` when the viewer may
  not read it, otherwise `{:ok, moderation_logs}` as a `m:Scrivener.Page`.
  """
  @spec load_moderation_logs(User.t() | nil, map() | keyword()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_moderation_logs(user, pagination) do
    with :ok <- authorize(user, :index, ModerationLog) do
      {:ok, list_moderation_logs(pagination)}
    end
  end

  @doc """
  Returns a paginated list of moderation logs as a `m:Scrivener.Page`.

  ## Examples

      iex> list_moderation_logs(page_size: 15)
      [%ModerationLog{}, ...]

  """
  def list_moderation_logs(pagination) do
    ModerationLog
    |> where([ml], ml.created_at >= ago(2, "week"))
    |> preload(:user)
    |> order_by(desc: :created_at)
    |> Repo.paginate(pagination)
  end

  @doc """
  Creates a moderation log.

  This is called from within the context function that performs the logged
  action, after that action succeeds - after the transaction commits, not
  inside it. `subject_path` is built with `Philomena.ModerationLogs.Paths`.

  ## Examples

      iex> create_moderation_log(%{field: value})
      {:ok, %ModerationLog{}}

      iex> create_moderation_log(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_moderation_log(user, type, subject_path, body) do
    %ModerationLog{user_id: user.id}
    |> ModerationLog.changeset(%{type: type, subject_path: subject_path, body: body})
    |> Repo.insert()
  end

  @doc """
  Removes moderation logs created more than 2 weeks ago.

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
