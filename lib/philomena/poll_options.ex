defmodule Philomena.PollOptions do
  @moduledoc """
  Poll option loading for the PollVotes aggregate.

  Poll options are not independent resources. Persistence is owned by the
  poll changeset and vote transactions.
  """

  import Ecto.Query, warn: false

  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.Multi
  alias Philomena.PollOptions.PollOption
  alias Philomena.Polls.Poll
  alias Philomena.Repo

  @doc """
  Loads every option belonging to `poll`.

  ## Examples

      iex> load_options(poll)
      [%PollOption{}, %PollOption{}]

  """
  @spec load_options(Poll.t()) :: [PollOption.t()]
  def load_options(%Poll{} = poll) do
    poll
    |> Repo.preload(:options)
    |> Map.fetch!(:options)
  end

  @doc """
  Safely loads one option beneath a loaded poll.

  ## Examples

      iex> load_option(poll, "1")
      {:ok, %PollOption{}}

  """
  @spec load_option(Poll.t(), IntegerId.integer_id()) ::
          {:ok, PollOption.t()} | {:error, :not_found}
  def load_option(%Poll{} = poll, id) do
    with {:ok, id} <- Loader.parse_id(id) do
      PollOption
      |> where([option], option.poll_id == ^poll.id and option.id == ^id)
      |> Loader.one()
    end
  end

  @doc """
  Adds a vote count adjustment for options belonging to `poll_id` to `multi`.

  The caller is responsible for locking the parent poll.
  """
  @spec put_vote_count_delta(
          Multi.t(),
          Multi.name(),
          integer(),
          (Multi.changes() -> [integer()]),
          integer()
        ) :: Multi.t()
  def put_vote_count_delta(%Multi{} = multi, step, poll_id, option_ids_callback, amount)
      when is_integer(poll_id) and is_integer(amount) do
    Multi.run(multi, step, fn repo, changes ->
      option_ids = option_ids_callback.(changes)

      query =
        PollOption
        |> where([option], option.id in ^option_ids and option.poll_id == ^poll_id)

      {:ok, repo.update_all(query, inc: [vote_count: amount])}
    end)
  end
end
