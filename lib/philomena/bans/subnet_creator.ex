defmodule Philomena.Bans.SubnetCreator do
  @moduledoc """
  Handles automatic creation of subnet bans for an input user ban.

  This prevents trivial ban evasion with the creation of a new account from the same address.
  The user must work around or wait out the subnet ban first.
  """

  alias Philomena.UserIps
  alias Philomena.Bans.Subnet
  alias Philomena.Repo

  @doc """
  Creates a subnet ban for the given user's last known IP address.

  Returns `{:ok, ban}`, `{:ok, nil}`, or `{:error, changeset}` for composition
  inside the user ban creation transaction.
  """
  @spec create_for_user(Philomena.Users.User.t(), pos_integer(), map()) ::
          {:ok, Subnet.t() | nil} | {:error, Ecto.Changeset.t()}
  def create_for_user(creator, user_id, attrs) do
    ip = UserIps.latest_ip_for_user(user_id)

    if ip do
      %Subnet{banning_user_id: creator.id}
      |> Subnet.changeset(Map.put(attrs, "specification", mask_ip(ip)))
      |> Repo.insert()
    else
      {:ok, nil}
    end
  end

  # IPv6 privacy addresses rotate their lower 64 bits. An automatic subnet ban
  # therefore covers the stable /64 prefix; IPv4 addresses remain unchanged.
  defp mask_ip(%Postgrex.INET{address: {_1, _2, _3, _4}} = ip), do: ip

  defp mask_ip(%Postgrex.INET{address: {h1, h2, h3, h4, _5, _6, _7, _8}} = ip) do
    %{ip | address: {h1, h2, h3, h4, 0, 0, 0, 0}, netmask: 64}
  end
end
