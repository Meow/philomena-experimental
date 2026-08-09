defmodule Philomena.PollOptions do
  @moduledoc """
  Safe parent-scoped poll-option loading for the PollVotes aggregate.

  Poll options are not independent resources. Persistence is owned by the
  poll changeset and vote transactions.
  """

  import Ecto.Query, warn: false

  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.PollOptions.PollOption
  alias Philomena.Polls.Poll
  alias Philomena.Repo

  defp parse_unique_ids(option_ids) when is_list(option_ids) and option_ids != [] do
    option_ids
    |> Enum.reduce_while({:ok, []}, fn option_id, {:ok, ids} ->
      case IntegerId.parse(option_id) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, ids} ->
        ids = Enum.reverse(ids)
        if Enum.uniq(ids) == ids, do: {:ok, ids}, else: {:error, :duplicate}

      error ->
        error
    end
  end

  defp parse_unique_ids(_option_ids), do: {:error, :not_found}

  @doc """
  Loads every selected option under `poll` while preserving input order.

  Empty, malformed, duplicate, missing, and wrong-poll IDs reject the entire
  selection. No user-controlled option ID can raise.

  ## Examples

      iex> load_selected_options(poll, ["1", "2"])
      {:ok, [%PollOption{}, %PollOption{}]}

      iex> load_selected_options(poll, ["1", "1"])
      {:error, :duplicate}

  """
  @spec load_selected_options(Poll.t(), [IntegerId.integer_id()]) ::
          {:ok, [PollOption.t()]} | {:error, :duplicate | :not_found}
  def load_selected_options(%Poll{} = poll, option_ids) do
    with {:ok, ids} <- parse_unique_ids(option_ids) do
      options =
        PollOption
        |> where([option], option.poll_id == ^poll.id and option.id in ^ids)
        |> Repo.all()

      options_by_id = Map.new(options, &{&1.id, &1})

      case Enum.map(ids, &Map.fetch(options_by_id, &1)) do
        results when length(options) == length(ids) ->
          {:ok, Enum.map(results, fn {:ok, option} -> option end)}

        _results ->
          {:error, :not_found}
      end
    end
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
    with {:ok, id} <- IntegerId.parse(id) do
      PollOption
      |> where([option], option.poll_id == ^poll.id and option.id == ^id)
      |> Loader.one()
    else
      :error -> {:error, :not_found}
    end
  end
end
