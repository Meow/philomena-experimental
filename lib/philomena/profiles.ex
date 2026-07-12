defmodule Philomena.Profiles do
  @moduledoc """
  Assembly of the data behind a user's profile page and its admin-only history
  views, scoped to the viewer.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Users.User
  alias Philomena.UserIps.UserIp
  alias Philomena.UserFingerprints.UserFingerprint

  @doc """
  Loads the IP history of the user named by the profile `slug`, on behalf of
  `actor`: every IP address the user has been seen on, and the other users seen
  on those same addresses.

  The user is loaded by slug and authorized for `:show_details`; an unknown slug
  authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for viewers whose grants
  cover `nil`).

  Returns `{:ok, %{user: user, user_ips: [...], other_users: %{ip => [...]}}}`.
  """
  @spec load_ip_history(User.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :unauthorized | :not_found}
  def load_ip_history(actor, slug) do
    with {:ok, user} <- load_detailed_profile(actor, slug) do
      user_ips =
        UserIp
        |> where(user_id: ^user.id)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()

      distinct_ips =
        user_ips
        |> Enum.map(& &1.ip)
        |> Enum.uniq()

      other_users =
        UserIp
        |> where([u], u.ip in ^distinct_ips)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()
        |> Enum.group_by(& &1.ip)

      {:ok, %{user: user, user_ips: user_ips, other_users: other_users}}
    end
  end

  @doc """
  Loads the fingerprint history of the user named by the profile `slug`, on
  behalf of `actor`: every fingerprint the user has been seen with, and the
  other users seen with those same fingerprints.

  The user is loaded by slug and authorized for `:show_details`; an unknown slug
  authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for viewers whose grants
  cover `nil`).

  Returns `{:ok, %{user: user, user_fps: [...], other_users: %{fp => [...]}}}`.
  """
  @spec load_fp_history(User.t() | nil, String.t()) ::
          {:ok, map()} | {:error, :unauthorized | :not_found}
  def load_fp_history(actor, slug) do
    with {:ok, user} <- load_detailed_profile(actor, slug) do
      user_fps =
        UserFingerprint
        |> where(user_id: ^user.id)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()

      distinct_fps =
        user_fps
        |> Enum.map(& &1.fingerprint)
        |> Enum.uniq()

      other_users =
        UserFingerprint
        |> where([u], u.fingerprint in ^distinct_fps)
        |> preload(:user)
        |> order_by(desc: :updated_at)
        |> Repo.all()
        |> Enum.group_by(& &1.fingerprint)

      {:ok, %{user: user, user_fps: user_fps, other_users: other_users}}
    end
  end

  # Loads a user by profile slug and authorizes the viewer for `:show_details`.
  # An unknown slug authorizes a `nil` record, so a viewer whose grants do not
  # cover `nil` gets `{:error, :unauthorized}` and one permitted to act on `nil`
  # gets `{:error, :not_found}`.
  defp load_detailed_profile(actor, slug) do
    user = Repo.get_by(User, slug: slug)

    with :ok <- authorize(actor, :show_details, user),
         %User{} <- user do
      {:ok, user}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end
end
