defmodule Philomena.PollOptions do
  @moduledoc """
  Poll option loading for the PollVotes aggregate.

  Poll options are not independent resources. Persistence is owned by the
  poll changeset and vote transactions.
  """

  import Ecto.Query, warn: false

  alias Philomena.IntegerId
  alias Philomena.Loader
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
end
