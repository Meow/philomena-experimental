defmodule Philomena.UserIps.Server do
  @moduledoc """
  Batches user IP usage updates and submits them to the database every 60 seconds.
  """

  use GenServer

  import Ecto.Query

  alias Philomena.Repo
  alias Philomena.UserIps.UserIp

  @timeout 0
  @flush_interval to_timeout(second: 60)

  @doc """
  Starts the user IP usage server.
  """
  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Asynchronously records usage of an IP address by a user.

  Invalid IP addresses return `:error`.

  ## Example

      iex> record_usage(user, {127, 0, 0, 1}, ~U[2024-01-01 00:00:00Z])
      :ok

  """
  @spec record_usage(pos_integer(), term(), DateTime.t()) :: :ok | :error
  def record_usage(user_id, ip_address, updated_at) do
    with {:ok, ip_address} <- EctoNetwork.INET.cast(ip_address) do
      GenServer.cast(__MODULE__, {user_id, ip_address, updated_at})
    end
  end

  @impl true
  @doc false
  def init(_) do
    {:ok, %{}, @timeout}
  end

  @impl true
  @doc false
  def handle_cast({user_id, ip_address, updated_at}, user_ips) do
    {:noreply, Map.put(user_ips, {user_id, ip_address}, updated_at), @timeout}
  end

  @impl true
  @doc false
  def handle_info(:timeout, user_ips) do
    flush(user_ips)
    {:noreply, %{}, @flush_interval}
  end

  defp flush(user_ips) do
    if map_size(user_ips) > 0 do
      update_query =
        update(UserIp, inc: [uses: 1], set: [updated_at: fragment("EXCLUDED.updated_at")])

      Repo.insert_all(
        UserIp,
        Enum.map(user_ips, &into_insert_all/1),
        on_conflict: update_query,
        conflict_target: [:user_id, :ip]
      )
    end
  end

  defp into_insert_all({{user_id, ip_address}, updated_at}) do
    %{
      user_id: user_id,
      ip: ip_address,
      uses: 1,
      created_at: updated_at,
      updated_at: updated_at
    }
  end
end
