defmodule Philomena.SourceChanges do
  @moduledoc """
  Source URL edit history for images and attributed identities.

  This context resolves and authorizes image, user, IP, and fingerprint targets
  before querying history. Image histories follow image visibility; user
  histories require detailed-profile access; IP and fingerprint histories
  require the shared identity-metadata permission.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Attribution.Actor
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.SourceChanges.SourceChange
  alias Philomena.SourceChanges.SourceChangePage
  alias Philomena.UserFingerprints
  alias Philomena.Users
  alias Philomena.Users.User
  alias PhilomenaQuery.IpMask

  defp history_query(query) do
    query
    |> order_by(desc: :id)
    |> preload([:user, image: [:user, :sources, tags: :aliases]])
  end

  defp image_history_query(%Image{id: image_id}) do
    SourceChange
    |> where(image_id: ^image_id)
    |> history_query()
  end

  defp user_history_query(%User{id: user_id}) do
    SourceChange
    |> join(:inner, [source_change], image in Image, on: source_change.image_id == image.id)
    |> where(
      [source_change, image],
      source_change.user_id == ^user_id and
        not (image.user_id == ^user_id and image.anonymous == true)
    )
  end

  defp load_user_history_target(actor, slug) do
    with {:ok, user} <- Users.load_profile(actor, slug),
         :ok <- authorize(actor, :show_details, user) do
      {:ok, user}
    end
  end

  defp cast_ip(ip) do
    case EctoNetwork.INET.cast(ip) do
      {:ok, ip} -> {:ok, ip}
      _error -> {:error, :not_found}
    end
  end

  defp cast_fingerprint(fingerprint) when is_binary(fingerprint) do
    fingerprint = fingerprint |> String.trim() |> String.downcase()

    if UserFingerprints.valid_format?(fingerprint) do
      {:ok, fingerprint}
    else
      {:error, :not_found}
    end
  end

  defp cast_fingerprint(_fingerprint), do: {:error, :not_found}

  defp added_filter(query, %{"added" => "1"}), do: where(query, added: true)
  defp added_filter(query, %{"added" => "0"}), do: where(query, added: false)
  defp added_filter(query, _params), do: query

  @doc """
  Counts the history rows for an already-loaded image.

  This narrow composition service is used after Images has authorized and
  updated the image, so it does not resolve or authorize a raw locator itself.
  """
  @spec count_for_image(Image.t()) :: non_neg_integer()
  def count_for_image(%Image{id: image_id}) do
    SourceChange
    |> where(image_id: ^image_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Loads a page of source changes for the image named by `image_id`.

  Images owns target loading and `:show` authorization. Malformed and absent
  IDs are not found; an existing image hidden from the actor is unauthorized.
  Entries are newest first with their users and images preloaded.

  ## Examples

      iex> image_source_changes(actor, "42", page: 1, page_size: 25)
      {:ok, %SourceChangePage{target: %Image{}, source_changes: %Scrivener.Page{}}}

      iex> image_source_changes(actor, "missing", page: 1, page_size: 25)
      {:error, :not_found}
  """
  @spec image_source_changes(
          Actor.t(),
          Philomena.IntegerId.integer_id(),
          Repo.pagination_params()
        ) ::
          {:ok, SourceChangePage.t()} | {:error, :unauthorized | :not_found}
  def image_source_changes(%Actor{} = actor, image_id, pagination) do
    with {:ok, image} <- Images.load_visible_image(actor, image_id) do
      source_changes = image |> image_history_query() |> Repo.paginate(pagination)
      {:ok, %SourceChangePage{target: image, source_changes: source_changes}}
    end
  end

  @doc """
  Loads a page of source changes attributed to the active user named by `slug`.

  The user is resolved through Users before `:show_details` authorization, so
  missing and deactivated profiles are not found without revealing them through
  the permission result. No history or count query runs for a forbidden target.
  Changes to the user's own anonymous uploads are excluded. `params["added"]`
  may select additions (`"1"`) or removals (`"0"`). `image_count` counts the
  distinct images represented by the same filtered history query.

  ## Examples

      iex> user_source_changes(moderator, "artist", %{}, page: 1, page_size: 25)
      {:ok, %SourceChangePage{target: %User{}, image_count: 3}}
  """
  @spec user_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, SourceChangePage.t()} | {:error, :unauthorized | :not_found}
  def user_source_changes(%Actor{} = actor, slug, params, pagination) do
    with {:ok, user} <- load_user_history_target(actor, slug) do
      query = user |> user_history_query() |> added_filter(params)

      source_changes =
        query
        |> history_query()
        |> Repo.paginate(pagination)

      image_count =
        query
        |> select([_source_change, image], count(image.id, :distinct))
        |> Repo.one()

      {:ok,
       %SourceChangePage{
         target: user,
         source_changes: source_changes,
         image_count: image_count
       }}
    end
  end

  @doc """
  Loads a page of source changes attributed to `ip` or a requested subnet.

  The address is parsed before the identity-metadata permission is checked, so
  malformed addresses are always not found. Valid addresses with no history
  return an empty page. `params["mask"]` selects the queried subnet and
  `params["added"]` may select additions (`"1"`) or removals (`"0"`). The
  result target is the canonical address and `range` is the actual masked range.
  """
  @spec ip_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, SourceChangePage.t()} | {:error, :unauthorized | :not_found}
  def ip_source_changes(%Actor{} = actor, ip, params, pagination) do
    with {:ok, ip} <- cast_ip(ip),
         :ok <- authorize(actor, :show, :identity_metadata) do
      range = IpMask.parse_mask(ip, params)

      source_changes =
        SourceChange
        |> where(fragment("? >>= ip", ^range))
        |> added_filter(params)
        |> history_query()
        |> Repo.paginate(pagination)

      {:ok, %SourceChangePage{target: ip, range: range, source_changes: source_changes}}
    end
  end

  @doc """
  Loads a page of source changes attributed to a browser `fingerprint`.

  The value is trimmed, lowercased, and validated with UserFingerprints before
  the identity-metadata permission is checked. Malformed values are always not
  found; a valid fingerprint with no history returns an empty page.
  `params["added"]` may select additions (`"1"`) or removals (`"0"`).
  """
  @spec fingerprint_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, SourceChangePage.t()} | {:error, :unauthorized | :not_found}
  def fingerprint_source_changes(%Actor{} = actor, fingerprint, params, pagination) do
    with {:ok, fingerprint} <- cast_fingerprint(fingerprint),
         :ok <- authorize(actor, :show, :identity_metadata) do
      source_changes =
        SourceChange
        |> where(fingerprint: ^fingerprint)
        |> added_filter(params)
        |> history_query()
        |> Repo.paginate(pagination)

      {:ok, %SourceChangePage{target: fingerprint, source_changes: source_changes}}
    end
  end
end
