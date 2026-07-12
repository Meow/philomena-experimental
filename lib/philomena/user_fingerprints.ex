defmodule Philomena.UserFingerprints do
  @moduledoc """
  The UserFingerprints context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Bans
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.UserFingerprints.FingerprintProfile
  alias Philomena.Users.User

  @doc """
  Assembles the fingerprint profile page for `user` (the current viewer) from the
  raw `fingerprint` string.

  The profile is staff-only: a viewer who may not see fingerprints gets
  `{:error, :unauthorized}`. The fingerprint is matched as a raw string, so any
  value returns a (possibly empty) profile.

  Returns `{:ok, %FingerprintProfile{}}` carrying the users seen with the
  fingerprint and the fingerprint bans matching it.
  """
  @spec load_fingerprint_profile(User.t() | nil, String.t()) ::
          {:ok, FingerprintProfile.t()} | {:error, :unauthorized}
  def load_fingerprint_profile(user, fingerprint) do
    with :ok <- authorize(user, :show, :ip_address) do
      {:ok,
       %FingerprintProfile{
         fingerprint: fingerprint,
         user_fingerprints: user_fingerprints_for(fingerprint),
         fingerprint_bans: Bans.fingerprint_bans_for(fingerprint)
       }}
    end
  end

  defp user_fingerprints_for(fingerprint) do
    UserFingerprint
    |> where(fingerprint: ^fingerprint)
    |> order_by(desc: :updated_at)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Returns the list of user_fingerprints.

  ## Examples

      iex> list_user_fingerprints()
      [%UserFingerprint{}, ...]

  """
  def list_user_fingerprints do
    Repo.all(UserFingerprint)
  end

  @doc """
  Gets a single user_fingerprint.

  Raises `Ecto.NoResultsError` if the User fingerprint does not exist.

  ## Examples

      iex> get_user_fingerprint!(123)
      %UserFingerprint{}

      iex> get_user_fingerprint!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user_fingerprint!(id), do: Repo.get!(UserFingerprint, id)

  @doc """
  Creates a user_fingerprint.

  ## Examples

      iex> create_user_fingerprint(%{field: value})
      {:ok, %UserFingerprint{}}

      iex> create_user_fingerprint(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user_fingerprint(attrs \\ %{}) do
    %UserFingerprint{}
    |> UserFingerprint.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user_fingerprint.

  ## Examples

      iex> update_user_fingerprint(user_fingerprint, %{field: new_value})
      {:ok, %UserFingerprint{}}

      iex> update_user_fingerprint(user_fingerprint, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_fingerprint(%UserFingerprint{} = user_fingerprint, attrs) do
    user_fingerprint
    |> UserFingerprint.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a UserFingerprint.

  ## Examples

      iex> delete_user_fingerprint(user_fingerprint)
      {:ok, %UserFingerprint{}}

      iex> delete_user_fingerprint(user_fingerprint)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user_fingerprint(%UserFingerprint{} = user_fingerprint) do
    Repo.delete(user_fingerprint)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user_fingerprint changes.

  ## Examples

      iex> change_user_fingerprint(user_fingerprint)
      %Ecto.Changeset{source: %UserFingerprint{}}

  """
  def change_user_fingerprint(%UserFingerprint{} = user_fingerprint) do
    UserFingerprint.changeset(user_fingerprint, %{})
  end
end
