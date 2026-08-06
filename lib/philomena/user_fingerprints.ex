defmodule Philomena.UserFingerprints do
  @moduledoc """
  Actor-scoped fingerprint profiles and user-history reads, plus browser
  fingerprint validation.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.Bans
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.UserFingerprints.FingerprintProfile
  alias Philomena.Users.User

  @cross_reference_limit 50

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

  defp history_query(%User{id: user_id}) do
    UserFingerprint
    |> where(user_id: ^user_id)
    |> order_by(desc: :updated_at, desc: :id)
  end

  defp cross_references([]), do: %{}

  defp cross_references(fingerprints) do
    ranked_ids =
      UserFingerprint
      |> where([user_fingerprint], user_fingerprint.fingerprint in ^fingerprints)
      |> windows([user_fingerprint],
        identity: [
          partition_by: user_fingerprint.fingerprint,
          order_by: [desc: user_fingerprint.updated_at, desc: user_fingerprint.id]
        ]
      )
      |> select([user_fingerprint], %{
        id: user_fingerprint.id,
        rank: over(row_number(), :identity)
      })

    UserFingerprint
    |> join(:inner, [user_fingerprint], ranked in subquery(ranked_ids),
      on: ranked.id == user_fingerprint.id
    )
    |> where([_user_fingerprint, ranked], ranked.rank <= ^@cross_reference_limit)
    |> preload(:user)
    |> order_by([user_fingerprint], desc: user_fingerprint.updated_at, desc: user_fingerprint.id)
    |> Repo.all()
    |> Enum.group_by(& &1.fingerprint)
  end

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
  Loads a paginated fingerprint history for `user` and cross-references the
  fingerprints on the current page for `actor`.

  The actor must have the shared identity-metadata permission. Cross-references
  are capped at the 50 most recently used rows per fingerprint.

  ## Examples

      iex> load_user_history(moderator, user, page: 1, page_size: 25)
      {:ok, {%Scrivener.Page{}, %{"fingerprint" => [%UserFingerprint{}]}}}

  """
  @spec load_user_history(Actor.t(), User.t(), Repo.pagination_params()) ::
          {:ok, {Scrivener.Page.t(UserFingerprint.t()), map()}} | {:error, :unauthorized}
  def load_user_history(%Actor{} = actor, %User{} = user, pagination) do
    with :ok <- authorize(actor, :show, :identity_metadata) do
      user_fingerprints = user |> history_query() |> Repo.paginate(pagination)

      fingerprints =
        user_fingerprints.entries
        |> Enum.map(& &1.fingerprint)
        |> Enum.uniq()

      {:ok, {user_fingerprints, cross_references(fingerprints)}}
    end
  end

  @doc """
  Returns the latest fingerprint-history row for `user`, if any, after applying
  the shared identity-metadata permission.

  ## Examples

      iex> latest_for_user(moderator, user)
      {:ok, %UserFingerprint{}}

  """
  @spec latest_for_user(Actor.t(), User.t()) ::
          {:ok, UserFingerprint.t() | nil} | {:error, :unauthorized}
  def latest_for_user(%Actor{} = actor, %User{} = user) do
    with :ok <- authorize(actor, :show, :identity_metadata) do
      {:ok, user |> history_query() |> limit(1) |> Repo.one()}
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
