defmodule Philomena.UserIps do
  @moduledoc """
  The UserIps context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Bans
  alias Philomena.UserIps.UserIp
  alias Philomena.UserIps.IpProfile
  alias Philomena.Users.User

  @doc """
  Assembles the IP profile page for `user` (the current viewer) from the raw
  address string `ip`.

  The profile is staff-only: a viewer who may not see IP addresses gets
  `{:error, :unauthorized}` before the address is parsed, matching the order the
  authorization gate runs in. An unparsable address is `{:error, :not_found}`.

  Returns `{:ok, %IpProfile{}}` carrying the users seen on the address and the
  subnet bans covering it.
  """
  @spec load_ip_profile(User.t() | nil, String.t()) ::
          {:ok, IpProfile.t()} | {:error, :unauthorized | :not_found}
  def load_ip_profile(user, ip) do
    with :ok <- authorize(user, :show, :ip_address),
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
  Gets a single user_ip.

  Raises `Ecto.NoResultsError` if the User ip does not exist.

  ## Examples

      iex> get_user_ip!(123)
      %UserIp{}

      iex> get_user_ip!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user_ip!(id), do: Repo.get!(UserIp, id)

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

  @doc """
  Creates a user_ip.

  ## Examples

      iex> create_user_ip(%{field: value})
      {:ok, %UserIp{}}

      iex> create_user_ip(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user_ip(attrs \\ %{}) do
    %UserIp{}
    |> UserIp.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user_ip.

  ## Examples

      iex> update_user_ip(user_ip, %{field: new_value})
      {:ok, %UserIp{}}

      iex> update_user_ip(user_ip, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_ip(%UserIp{} = user_ip, attrs) do
    user_ip
    |> UserIp.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a UserIp.

  ## Examples

      iex> delete_user_ip(user_ip)
      {:ok, %UserIp{}}

      iex> delete_user_ip(user_ip)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user_ip(%UserIp{} = user_ip) do
    Repo.delete(user_ip)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user_ip changes.

  ## Examples

      iex> change_user_ip(user_ip)
      %Ecto.Changeset{source: %UserIp{}}

  """
  def change_user_ip(%UserIp{} = user_ip) do
    UserIp.changeset(user_ip, %{})
  end
end
