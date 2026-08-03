defmodule Philomena.UserIps do
  @moduledoc """
  IP history profiles and latest IP lookup for ban enforcement.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Bans
  alias Philomena.UserIps.UserIp
  alias Philomena.UserIps.IpProfile

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
  Assembles the IP profile page for `actor` from the raw address string `ip`.

  The address is parsed and canonicalized before the `:identity_metadata`
  permission is checked. A malformed address is therefore always not found; a
  valid address with no matching history returns an empty profile.

  Returns `{:ok, %IpProfile{}}` carrying the users seen on the address and the
  subnet bans covering it.
  """
  @spec load_ip_profile(Actor.t(), String.t()) ::
          {:ok, IpProfile.t()} | {:error, :unauthorized | :not_found}
  def load_ip_profile(%Actor{} = actor, ip) do
    with {:ok, ip} <- cast_ip(ip),
         :ok <- authorize(actor, :show, :identity_metadata) do
      {:ok,
       %IpProfile{
         ip: ip,
         user_ips: user_ips_for(ip),
         subnet_bans: Bans.subnet_bans_for_ip(ip)
       }}
    end
  end

  @doc """
  Returns the latest recorded IP for `user_id`, if any.

  This function is designed for automatic subnet creation when a user is
  banned. Request-facing code must use `load_ip_profile/2`, which applies the
  `:identity_metadata` permission.
  """
  @spec latest_ip_for_user(pos_integer()) :: Postgrex.INET.t() | nil
  def latest_ip_for_user(user_id) do
    UserIp
    |> where(user_id: ^user_id)
    |> order_by(desc: :updated_at)
    |> limit(1)
    |> select([u], u.ip)
    |> Repo.one()
  end
end
