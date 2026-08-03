defmodule Philomena.UserFingerprints do
  @moduledoc """
  The UserFingerprints context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Bans
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.UserFingerprints.FingerprintProfile

  @doc """
  Assembles the fingerprint profile page for `actor` from the raw
  `fingerprint` string.

  The profile is staff-only: a viewer who may not see fingerprints gets
  `{:error, :unauthorized}`. The fingerprint is matched as a raw string, so any
  value returns a (possibly empty) profile.

  Returns `{:ok, %FingerprintProfile{}}` carrying the users seen with the
  fingerprint and the fingerprint bans matching it.
  """
  @spec load_fingerprint_profile(Actor.t(), String.t()) ::
          {:ok, FingerprintProfile.t()} | {:error, :unauthorized}
  def load_fingerprint_profile(%Actor{} = actor, fingerprint) do
    with :ok <- authorize(actor, :show, :ip_address) do
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
end
