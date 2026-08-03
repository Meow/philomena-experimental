defmodule Philomena.UserFingerprints do
  @moduledoc """
  Fingerprint history profiles and browser fingerprint validation.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Bans
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.UserFingerprints.FingerprintProfile

  defp user_fingerprints_for(fingerprint) do
    UserFingerprint
    |> where(fingerprint: ^fingerprint)
    |> order_by(desc: :updated_at)
    |> preload(:user)
    |> Repo.all()
  end

  defp cast_fingerprint(fingerprint) when is_binary(fingerprint) do
    fingerprint = fingerprint |> String.trim() |> String.downcase()

    if valid_format?(fingerprint), do: {:ok, fingerprint}, else: {:error, :not_found}
  end

  defp cast_fingerprint(_fingerprint), do: {:error, :not_found}

  @doc """
  Assembles the fingerprint profile page for `actor` from the raw
  `fingerprint` string.

  The input is trimmed, lowercased, and validated before the `:identity_metadata`
  permission is checked. Malformed fingerprints are therefore always not found.
  Valid fingerprints with no matching history return an empty profile.

  Returns `{:ok, %FingerprintProfile{}}` carrying the users seen with the
  fingerprint and the fingerprint bans matching it.
  """
  @spec load_fingerprint_profile(Actor.t(), String.t()) ::
          {:ok, FingerprintProfile.t()} | {:error, :unauthorized | :not_found}
  def load_fingerprint_profile(%Actor{} = actor, fingerprint) do
    with {:ok, fingerprint} <- cast_fingerprint(fingerprint),
         :ok <- authorize(actor, :show, :identity_metadata) do
      {:ok,
       %FingerprintProfile{
         fingerprint: fingerprint,
         user_fingerprints: user_fingerprints_for(fingerprint),
         fingerprint_bans: Bans.fingerprint_bans_for(fingerprint)
       }}
    end
  end

  @doc """
  Returns whether `fingerprint` uses a supported browser fingerprint format.

  Legacy `c` fingerprints contain a decimal hash of at most 12 digits. Current
  `d` fingerprints contain exactly 14 lowercase hexadecimal digits.
  """
  @spec valid_format?(term()) :: boolean()
  def valid_format?(fingerprint)

  def valid_format?(<<"c", rest::binary>>) when byte_size(rest) <= 12 do
    match?({_result, ""}, Integer.parse(rest))
  end

  def valid_format?(<<"d", rest::binary>>) when byte_size(rest) == 14 do
    match?({:ok, _result}, Base.decode16(rest, case: :lower))
  end

  def valid_format?(_fingerprint), do: false
end
