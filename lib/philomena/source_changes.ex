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
  alias Philomena.SourceChanges.QueryBuilder
  alias Philomena.SourceChanges.QueryForm
  alias Philomena.SourceChanges.SourceChangePage
  alias Philomena.UserFingerprints
  alias Philomena.Users
  alias PhilomenaQuery.IpMask

  @preloads [:user, image: [:user, :sources, tags: :aliases]]

  defp cast_ip(ip) do
    case EctoNetwork.INET.cast(ip) do
      {:ok, ip} ->
        {:ok, ip}

      _error ->
        {:error, :not_found}
    end
  end

  defp cast_fingerprint(fingerprint) when is_binary(fingerprint) do
    fingerprint =
      fingerprint
      |> String.trim()
      |> String.downcase()

    if UserFingerprints.valid_format?(fingerprint) do
      {:ok, fingerprint}
    else
      {:error, :not_found}
    end
  end

  defp cast_fingerprint(_fingerprint), do: {:error, :not_found}

  @doc """
  Counts the history rows for an already-loaded image.

  This composition service is used after Images has authorized and
  updated the image, so it does not resolve or authorize a raw locator itself.

  ## Examples

      iex> count_for_image(image)
      3

  """
  @spec count_for_image(Image.t()) :: non_neg_integer()
  def count_for_image(%Image{id: image_id}) do
    SourceChange
    |> where(image_id: ^image_id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Builds a lateral query that counts source changes for the image in the
  parent query.

  The returned query expects an `:image` parent binding and is intended for
  use with `Ecto.Query.subquery/1`.

  ## Examples

      iex> SourceChanges.count_query()
      #Ecto.Query<...>

  """
  @spec count_query() :: Ecto.Query.t()
  def count_query do
    SourceChange
    |> where(image_id: parent_as(:image).id)
    |> select(%{count: count()})
  end

  @doc """
  Loads a page of source changes for the image named by `image_id`.

  Images owns target loading and `:show` authorization. Malformed and absent
  IDs are not found; an existing image hidden from the actor is unauthorized.
  Entries are newest first with their users and images preloaded.

  ## Examples

      iex> image_source_changes(actor, "42", %{}, page: 1, page_size: 25)
      {:ok, %SourceChangePage{target: %Image{}, source_changes: %Scrivener.Page{}}, changeset}

      iex> image_source_changes(actor, "missing", %{}, page: 1, page_size: 25)
      {:error, :not_found}

  """
  @spec image_source_changes(
          Actor.t(),
          Philomena.IntegerId.integer_id(),
          map(),
          Repo.pagination_params()
        ) ::
          {:ok, SourceChangePage.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def image_source_changes(%Actor{} = actor, image_id, params, pagination) do
    with {:ok, image} <- Images.load_visible_image(actor, image_id),
         {:ok, query, query_form} <- QueryBuilder.build_query(params) do
      source_changes =
        query
        |> where(image_id: ^image.id)
        |> preload(^@preloads)
        |> Repo.paginate(pagination)

      page = %SourceChangePage{target: image, source_changes: source_changes}

      {:ok, page, QueryForm.changeset(query_form)}
    end
  end

  @doc """
  Loads a page of source changes attributed to the active user named by `slug`.

  Missing and deactivated profiles are not found. No history or count query
  runs for a forbidden target. Changes to the user's own anonymous uploads are
  excluded. `params` may include an `added` filter (`true`/`"1"` for additions,
  `false`/`"0"` for removals). `image_count` counts the distinct images
  represented by the same filtered history query. The successful result includes
  the normalized query changeset.

  ## Examples

      iex> user_source_changes(moderator, "artist", %{}, page: 1, page_size: 25)
      {:ok, %SourceChangePage{target: %User{}, image_count: 3}, changeset}

      iex> user_source_changes(moderator, "missing", %{}, page: 1, page_size: 25)
      {:error, :not_found}

  """
  @spec user_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, SourceChangePage.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def user_source_changes(%Actor{} = actor, slug, params, pagination) do
    with {:ok, user} <- Users.load_profile(actor, slug),
         :ok <- authorize(actor, :show, user),
         {:ok, query, query_form} <- QueryBuilder.build_query(params) do
      query =
        query
        |> join(:inner, [source_change], _ in assoc(source_change, :image))
        |> where(
          [source_change, image],
          source_change.user_id == ^user.id and
            not (image.user_id == ^user.id and image.anonymous == true)
        )

      source_changes =
        query
        |> preload(^@preloads)
        |> Repo.paginate(pagination)

      image_count =
        query
        |> exclude(:order_by)
        |> select([_source_change, image], count(image.id, :distinct))
        |> Repo.one()

      page = %SourceChangePage{
        target: user,
        source_changes: source_changes,
        image_count: image_count
      }

      {:ok, page, QueryForm.changeset(query_form)}
    end
  end

  @doc """
  Loads a page of source changes attributed to `ip` or a requested subnet.

  The address is parsed before the identity-metadata permission is checked, so
  malformed addresses are always not found. Valid addresses with no history
  return an empty page. `params["mask"]` selects the queried subnet. `params`
  may include an `added` filter (`true`/`"1"` for additions, `false`/`"0"` for
  removals). The result target is the canonical address and `range` is the
  actual masked range.

  The successful result includes the normalized query changeset.

  ## Examples

      iex> ip_source_changes(moderator, "203.0.113.5", %{}, page: 1, page_size: 25)
      {:ok, %SourceChangePage{target: %Postgrex.INET{}, range: %Postgrex.INET{}}, changeset}

      iex> ip_source_changes(moderator, "not-an-ip", %{}, page: 1, page_size: 25)
      {:error, :not_found}

  """
  @spec ip_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, SourceChangePage.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def ip_source_changes(%Actor{} = actor, ip, params, pagination) do
    with {:ok, ip} <- cast_ip(ip),
         :ok <- authorize(actor, :show, :identity_metadata),
         {:ok, query, query_form} <- QueryBuilder.build_query(params) do
      range = IpMask.parse_mask(ip, params)

      source_changes =
        query
        |> where(fragment("? >>= ip", ^range))
        |> preload(^@preloads)
        |> Repo.paginate(pagination)

      page = %SourceChangePage{target: ip, range: range, source_changes: source_changes}

      {:ok, page, QueryForm.changeset(query_form)}
    end
  end

  @doc """
  Loads a page of source changes attributed to a browser `fingerprint`.

  The value is trimmed, lowercased, and validated with UserFingerprints before
  the identity-metadata permission is checked. Malformed values are always not
  found. A valid fingerprint with no history returns an empty page.

  `params` may include an `added` filter (`true`/`"1"` for additions, `false`/
  `"0"` for removals). The successful result includes the normalized query
  changeset.

  ## Examples

      iex> fingerprint_source_changes(moderator, "c123", %{}, page: 1, page_size: 25)
      {:ok, %SourceChangePage{target: "c123"}, changeset}

      iex> fingerprint_source_changes(moderator, "invalid", %{}, page: 1, page_size: 25)
      {:error, :not_found}

  """
  @spec fingerprint_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, SourceChangePage.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def fingerprint_source_changes(%Actor{} = actor, fingerprint, params, pagination) do
    with {:ok, fingerprint} <- cast_fingerprint(fingerprint),
         :ok <- authorize(actor, :show, :identity_metadata),
         {:ok, query, query_form} <- QueryBuilder.build_query(params) do
      source_changes =
        query
        |> where(fingerprint: ^fingerprint)
        |> preload(^@preloads)
        |> Repo.paginate(pagination)

      page = %SourceChangePage{target: fingerprint, source_changes: source_changes}

      {:ok, page, QueryForm.changeset(query_form)}
    end
  end
end
