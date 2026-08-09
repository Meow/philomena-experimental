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

  defp parse_unique_ids(option_ids) when is_list(option_ids) and option_ids != [] do
    ids =
      option_ids
      |> Enum.map(&IntegerId.parse/1)
      |> Enum.map(fn
        {:ok, id} -> id
        _ -> :error
      end)

    cond do
      :error in ids ->
        {:error, :not_found}

      Enum.uniq(ids) != ids ->
        {:error, :duplicate}

      true ->
        {:ok, ids}
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
        |> Map.new(&{&1.id, &1})

      ids
      |> Enum.map(&Map.get(options, &1))
      |> Enum.reject(&is_nil/1)
      |> case do
        results when map_size(options) == length(ids) ->
          {:ok, results}

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
    case IntegerId.parse(id) do
      {:ok, id} ->
        PollOption
        |> where([option], option.poll_id == ^poll.id and option.id == ^id)
        |> Loader.one()

      :error ->
        {:error, :not_found}
    end
  end
end
