defmodule Philomena.UserFingerprints.Server do
  @moduledoc """
  Batches user fingerprint usage updates and submits them to the database every
  60 seconds.
  """

  use GenServer

  import Ecto.Query

  alias Philomena.Repo
  alias Philomena.UserFingerprints
  alias Philomena.UserFingerprints.UserFingerprint

  @timeout 0
  @flush_interval to_timeout(second: 60)

  @doc """
  Starts the user fingerprint usage server.
  """
  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Asynchronously records usage of a fingerprint by a user.

  Invalid fingerprints return `:error`.

  ## Example

      iex> record_usage(user, "d63c4581f8cf58d", ~U[2024-01-01 00:00:00Z])
      :ok

  """
  @spec record_usage(pos_integer(), term(), DateTime.t()) :: :ok | :error
  def record_usage(user_id, fingerprint, updated_at) do
    if UserFingerprints.valid_format?(fingerprint) do
      GenServer.cast(__MODULE__, {user_id, fingerprint, updated_at})
    else
      :error
    end
  end

  @impl true
  @doc false
  def init(_) do
    {:ok, %{}, @timeout}
  end

  @impl true
  @doc false
  def handle_cast({user_id, fingerprint, updated_at}, user_fingerprints) do
    {:noreply, Map.put(user_fingerprints, {user_id, fingerprint}, updated_at), @timeout}
  end

  @impl true
  @doc false
  def handle_info(:timeout, user_fingerprints) do
    flush(user_fingerprints)
    {:noreply, %{}, @flush_interval}
  end

  defp flush(user_fingerprints) do
    if map_size(user_fingerprints) > 0 do
      update_query =
        update(UserFingerprint,
          inc: [uses: 1],
          set: [updated_at: fragment("EXCLUDED.updated_at")]
        )

      Repo.insert_all(
        UserFingerprint,
        Enum.map(user_fingerprints, &into_insert_all/1),
        on_conflict: update_query,
        conflict_target: [:user_id, :fingerprint]
      )
    end
  end

  defp into_insert_all({{user_id, fingerprint}, updated_at}) do
    %{
      user_id: user_id,
      fingerprint: fingerprint,
      uses: 1,
      created_at: updated_at,
      updated_at: updated_at
    }
  end
end
