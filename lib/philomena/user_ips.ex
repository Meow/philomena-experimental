defmodule Philomena.UserIps do
  @moduledoc """
  Actor-scoped IP profiles and user-history reads, plus the narrow latest-IP
  lookup used by automatic ban enforcement.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Bans
  alias Philomena.UserIps.UserIp
  alias Philomena.UserIps.IpProfile
  alias Philomena.Users.User

  @cross_reference_limit 50

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

  defp history_query(%User{id: user_id}) do
    UserIp
    |> where(user_id: ^user_id)
    |> order_by(desc: :updated_at, desc: :id)
  end

  defp cross_references([]), do: %{}

  defp cross_references(ips) do
    ranked_ids =
      UserIp
      |> where([user_ip], user_ip.ip in ^ips)
      |> windows([user_ip],
        identity: [
          partition_by: user_ip.ip,
          order_by: [desc: user_ip.updated_at, desc: user_ip.id]
        ]
      )
      |> select([user_ip], %{
        id: user_ip.id,
        rank: over(row_number(), :identity)
      })

    UserIp
    |> join(:inner, [user_ip], ranked in subquery(ranked_ids), on: ranked.id == user_ip.id)
    |> where([_user_ip, ranked], ranked.rank <= ^@cross_reference_limit)
    |> preload(:user)
    |> order_by([user_ip], desc: user_ip.updated_at, desc: user_ip.id)
    |> Repo.all()
    |> Enum.group_by(& &1.ip)
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
  Loads a paginated IP history for `user` and cross-references the IPs on the
  current page for `actor`.

  The actor must have the shared identity-metadata permission. Cross-references
  are capped at the 50 most recently used rows per IP.

  ## Examples

      iex> load_user_history(moderator, user, page: 1, page_size: 25)
      {:ok, {%Scrivener.Page{}, %{ip => [%UserIp{}]}}}

  """
  @spec load_user_history(Actor.t(), User.t(), Repo.pagination_params()) ::
          {:ok, {Scrivener.Page.t(UserIp.t()), map()}} | {:error, :unauthorized}
  def load_user_history(%Actor{} = actor, %User{} = user, pagination) do
    with :ok <- authorize(actor, :show, :identity_metadata) do
      user_ips = user |> history_query() |> Repo.paginate(pagination)
      ips = user_ips.entries |> Enum.map(& &1.ip) |> Enum.uniq()

      {:ok, {user_ips, cross_references(ips)}}
    end
  end

  @doc """
  Returns the latest IP-history row for `user`, if any, after applying the
  shared identity-metadata permission.

  ## Examples

      iex> latest_for_user(moderator, user)
      {:ok, %UserIp{}}

  """
  @spec latest_for_user(Actor.t(), User.t()) ::
          {:ok, UserIp.t() | nil} | {:error, :unauthorized}
  def latest_for_user(%Actor{} = actor, %User{} = user) do
    with :ok <- authorize(actor, :show, :identity_metadata) do
      {:ok, user |> history_query() |> limit(1) |> Repo.one()}
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
