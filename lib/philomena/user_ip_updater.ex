defmodule Philomena.UserIpUpdater do
  use GenServer

  import Ecto.Query

  alias Philomena.Repo
  alias Philomena.UserIps.UserIp

  @flush_interval :timer.seconds(60)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def cast(user_id, ip_address, updated_at) do
    GenServer.cast(__MODULE__, {user_id, ip_address, updated_at})
  end

  @impl GenServer
  def init([]) do
    {:ok, %{}, {:continue, :flush}}
  end

  @impl GenServer
  def handle_continue(:flush, user_ips) do
    flush(user_ips)
    {:noreply, %{}, @flush_interval}
  end

  @impl GenServer
  def handle_cast({user_id, ip_address, updated_at}, user_ips) do
    {:noreply, Map.put(user_ips, {user_id, ip_address}, updated_at)}
  end

  @impl GenServer
  def handle_info(:timeout, user_ips) do
    flush(user_ips)
    {:noreply, %{}, @flush_interval}
  end

  defp flush(user_ips) do
    update_query =
      update(UserIp, inc: [uses: 1], set: [updated_at: fragment("EXCLUDED.updated_at")])

    Repo.insert_all(UserIp, Enum.map(user_ips, &into_insert_all/1),
      on_conflict: update_query,
      conflict_target: [:user_id, :ip]
    )
  end

  defp into_insert_all({{user_id, ip_address}, updated_at}) do
    {:ok, ip} = EctoNetwork.INET.cast(ip_address)

    %{
      user_id: user_id,
      ip: ip,
      uses: 1,
      created_at: updated_at,
      updated_at: updated_at
    }
  end
end
