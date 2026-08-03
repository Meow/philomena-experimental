defmodule Philomena.UserIps do
  @moduledoc """
  The UserIps context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Bans
  alias Philomena.UserIps.UserIp
  alias Philomena.UserIps.IpProfile

  @doc """
  Assembles the IP profile page for `actor` from the raw address string `ip`.

  The profile is staff-only: a viewer who may not see IP addresses gets
  `{:error, :unauthorized}` before the address is parsed, matching the order the
  authorization gate runs in. An unparsable address is `{:error, :not_found}`.

  Returns `{:ok, %IpProfile{}}` carrying the users seen on the address and the
  subnet bans covering it.
  """
  @spec load_ip_profile(Actor.t(), String.t()) ::
          {:ok, IpProfile.t()} | {:error, :unauthorized | :not_found}
  def load_ip_profile(%Actor{} = actor, ip) do
    with :ok <- authorize(actor, :show, :ip_address),
         {:ok, ip} <- cast_ip(ip) do
      {:ok,
       %IpProfile{
         ip: ip,
         user_ips: user_ips_for(ip),
         subnet_bans: Bans.subnet_bans_for_ip(ip)
       }}
    end
  end

  defp user_ips_for(ip) do
    UserIp
    |> where(fragment("? >>= ip", ^ip))
    |> order_by(desc: :updated_at)
    |> preload(:user)
    |> Repo.all()
  end

  defp cast_ip(ip) do
    case EctoNetwork.INET.cast(ip) do
      {:ok, ip} -> {:ok, ip}
      _error -> {:error, :not_found}
    end
  end

  @doc """
  Gets this user's most recent IP address, if the user has one
  recorded.
  """
  def get_ip_for_user(user_id) do
    UserIp
    |> where(user_id: ^user_id)
    |> order_by(desc: :updated_at)
    |> limit(1)
    |> select([u], u.ip)
    |> Repo.one()
  end

  @doc """
  Sets the appropriate netmask for correctly banning an IPv6-enabled
  client per RFC4941. IPv4 addresses are not changed.
  """
  def masked_ip(%Postgrex.INET{address: {_1, _2, _3, _4}} = ip) do
    ip
  end

  def masked_ip(%Postgrex.INET{address: {h1, h2, h3, h4, _5, _6, _7, _8}} = ip) do
    %{ip | address: {h1, h2, h3, h4, 0, 0, 0, 0}, netmask: 64}
  end
end
