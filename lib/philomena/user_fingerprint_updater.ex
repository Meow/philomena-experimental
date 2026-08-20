defmodule Philomena.UserFingerprintUpdater do
  use GenServer

  import Ecto.Query

  alias Philomena.Repo
  alias Philomena.UserFingerprints
  alias Philomena.UserFingerprints.UserFingerprint

  @flush_interval :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def cast(user_id, fingerprint, updated_at) do
    if UserFingerprints.valid_format?(fingerprint) do
      GenServer.cast(__MODULE__, {user_id, fingerprint, updated_at})
    end
  end

  @impl GenServer
  def init([]) do
    {:ok, %{}, {:continue, :flush}}
  end

  @impl GenServer
  def handle_continue(:flush, user_fingerprints) do
    flush(user_fingerprints)
    {:noreply, %{}, @flush_interval}
  end

  @impl GenServer
  def handle_cast({user_id, fingerprint, updated_at}, user_fingerprints) do
    {:noreply, Map.put(user_fingerprints, {user_id, fingerprint}, updated_at)}
  end

  @impl GenServer
  def handle_info(:timeout, user_fingerprints) do
    flush(user_fingerprints)
    {:noreply, %{}, @flush_interval}
  end

  defp flush(user_fingerprints) do
    update_query =
      update(UserFingerprint, inc: [uses: 1], set: [updated_at: fragment("EXCLUDED.updated_at")])

    Repo.insert_all(UserFingerprint, Enum.map(user_fingerprints, &into_insert_all/1),
      on_conflict: update_query,
      conflict_target: [:user_id, :fingerprint]
    )
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
