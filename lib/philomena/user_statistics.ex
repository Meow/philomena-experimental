defmodule Philomena.UserStatistics do
  @moduledoc """
  Atomic daily counters derived from user activity.

  This module performs no authorization. It accepts a statistic key, and
  updates the user's lifetime counter and UTC daily row together.
  """

  import Ecto.Query, warn: false

  alias Philomena.Multi
  alias Philomena.Repo
  alias Philomena.Users
  alias Philomena.Users.User
  alias Philomena.UserStatistics.UserStatistic

  @permitted_actions [
    :images_count,
    :image_faves_count,
    :comments_count,
    :image_votes_count,
    :metadata_updates_count,
    :posts_count,
    :topics_count
  ]

  @typedoc "A daily and lifetime counter owned by this context."
  @type statistic ::
          :images_count
          | :image_faves_count
          | :comments_count
          | :image_votes_count
          | :metadata_updates_count
          | :posts_count
          | :topics_count

  defp persist_increment(user_id, statistic, amount) do
    day = Date.utc_today()
    user_query = where(User, id: ^user_id)

    Repo.transact(fn ->
      case Repo.update_all(user_query, inc: [{statistic, amount}]) do
        {1, nil} ->
          Repo.insert(
            Map.put(%UserStatistic{day: day, user_id: user_id}, statistic, amount),
            on_conflict: [inc: [{statistic, amount}]],
            conflict_target: [:day, :user_id]
          )

        {0, nil} ->
          {:error, :not_found}
      end
    end)
  end

  defp reindex_result({:ok, %UserStatistic{}}, user_id) do
    Users.reindex_user(%User{id: user_id})
    {:ok, nil}
  end

  defp reindex_result(error, _user_id), do: error

  @doc """
  Adds an atomic statistic increment to `multi`.

  The Multi updates both the user's lifetime counter and current UTC-daily
  counter. Passing `nil` leaves the Multi unchanged, which supports anonymous
  activity. After the transaction commits, it reindexes the user.

  ## Example

      iex> Multi.new() |> put_increment(user, :images_count, 2)
      %Multi{}

  """
  @spec put_increment(Multi.t(), User.t() | integer() | nil, statistic(), integer()) ::
          Multi.t()
  def put_increment(multi, user_or_id, statistic, amount \\ 1)

  def put_increment(multi, nil, statistic, amount)
      when statistic in @permitted_actions and is_integer(amount),
      do: multi

  def put_increment(multi, %User{} = user, statistic, amount)
      when statistic in @permitted_actions and is_integer(amount),
      do: put_increment(multi, user.id, statistic, amount)

  def put_increment(multi, user_id, statistic, amount)
      when is_integer(user_id) and statistic in @permitted_actions and is_integer(amount) do
    multi
    |> Multi.run({:put_increment, user_id}, fn _repo, _changes ->
      persist_increment(user_id, statistic, amount)
    end)
    |> Multi.on_commit(fn _changes ->
      Users.reindex_user(%User{id: user_id})
    end)
  end

  @doc """
  Atomically increments one lifetime and UTC-daily statistic for `user_or_id`.

  A `nil` user is an intentional no-op for anonymous activity. A missing user
  ID is `{:error, :not_found}`. Negative amounts decrement both counters.
  Unknown statistic keys and non-integer amounts do not match this API.

  The database increments join an ambient transaction when called from an
  `Ecto.Multi` callback, so an owning action rollback also rolls them back. A
  successful call enqueues a user reindex; that queue side effect is best-effort
  and is not part of the database transaction.

  ## Examples

      iex> increment(user, :images_count)
      {:ok, nil}

      iex> increment(user.id, :images_count, -1)
      {:ok, nil}

      iex> increment(nil, :comments_count)
      {:ok, nil}

  """
  @spec increment(User.t() | integer() | nil, statistic(), integer()) ::
          {:ok, nil} | {:error, :not_found | Ecto.Changeset.t()}
  def increment(user_or_id, statistic, amount \\ 1)

  def increment(nil, statistic, amount)
      when statistic in @permitted_actions and is_integer(amount),
      do: {:ok, nil}

  def increment(%User{} = user, statistic, amount)
      when statistic in @permitted_actions and is_integer(amount),
      do: increment(user.id, statistic, amount)

  def increment(user_id, statistic, amount)
      when is_integer(user_id) and statistic in @permitted_actions and is_integer(amount) do
    user_id
    |> persist_increment(statistic, amount)
    |> reindex_result(user_id)
  end
end
