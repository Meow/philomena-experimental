defmodule Philomena.SourceChanges do
  @moduledoc """
  The SourceChanges context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Attribution.Actor
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.Images.Image
  alias Philomena.Users.User
  alias Philomena.SourceChanges.SourceChange
  alias PhilomenaQuery.IpMask

  @doc """
  Counts the source changes recorded on the image with the given id.

  ## Examples

      iex> count_for_image(42)
      3

  """
  @spec count_for_image(integer()) :: non_neg_integer()
  def count_for_image(image_id) do
    SourceChange
    |> where(image_id: ^image_id)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Lists the source changes recorded on the image named by `image_id`, newest
  first, on behalf of `actor`.

  The image is loaded by id and authorized for `:show`.

  Returns `{:ok, {image, source_changes}}` where `source_changes` is a paginated
  set with its user and image associations preloaded.

  ## Examples

      iex> image_source_changes(user, "42", page: 1, page_size: 25)
      {:ok, {%Image{}, %Scrivener.Page{}}}

      iex> image_source_changes(user, "999999999", page: 1, page_size: 25)
      {:error, :unauthorized}

  """
  @spec image_source_changes(Actor.t(), IntegerId.integer_id(), Repo.pagination_params()) ::
          {:ok, {Image.t(), Scrivener.Page.t()}}
          | {:error, :unauthorized | :not_found}
  def image_source_changes(%Actor{} = actor, image_id, pagination) do
    with {:ok, id} <- Loader.parse_id(image_id),
         image = Repo.get(Image, id),
         :ok <- authorize(actor, :show, image),
         %Image{} <- image do
      source_changes =
        SourceChange
        |> where(image_id: ^image.id)
        |> preload([:user, image: [:user, :sources, tags: :aliases]])
        |> order_by(desc: :id)
        |> Repo.paginate(pagination)

      {:ok, {image, source_changes}}
    else
      # Non-castable id, or a `nil` load the actor was permitted to act on.
      shape when shape in [{:error, :not_found}, :error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Lists the source changes made by the user named by the profile `slug`, newest
  first, on behalf of `actor`.

  The user is loaded by slug and authorized for `:show`. Changes to the user's
  own anonymous uploads are excluded. `params["added"]` narrows to additions
  (`"1"`) or removals (`"0"`).

  Returns `{:ok, {user, source_changes, image_count}}` where `source_changes` is
  a paginated set with its user and image associations preloaded
  and `image_count` is the number of distinct images touched.

  ## Examples

      iex> user_source_changes(actor, "artist", %{}, page: 1, page_size: 25)
      {:ok, {%User{}, %Scrivener.Page{}, 3}}

  """
  @spec user_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, {User.t(), Scrivener.Page.t(), non_neg_integer()}}
          | {:error, :unauthorized | :not_found}
  def user_source_changes(%Actor{} = actor, slug, params, pagination) do
    user = Repo.get_by(User, slug: slug)

    with :ok <- authorize(actor, :show, user),
         %User{} <- user do
      common_query =
        SourceChange
        |> join(:inner, [sc], i in Image, on: sc.image_id == i.id)
        |> where(
          [sc, i],
          sc.user_id == ^user.id and not (i.user_id == ^user.id and i.anonymous == true)
        )
        |> added_filter(params)

      source_changes =
        common_query
        |> preload([:user, image: [:user, :sources, tags: :aliases]])
        |> order_by(desc: :id)
        |> Repo.paginate(pagination)

      image_count =
        common_query
        |> select([_, i], count(i.id, :distinct))
        |> Repo.one()

      {:ok, {user, source_changes, image_count}}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Lists the source changes attributed to the IP address `ip`, newest first, on
  behalf of `actor`.

  Listing is staff-only: a viewer who may not see IP addresses gets
  `{:error, :unauthorized}` before the address is parsed, matching the order the
  authorization gate runs in. An unparsable address is `{:error, :not_found}`.
  `params["mask"]` widens the query to a subnet; `params["added"]` narrows to
  additions (`"1"`) or removals (`"0"`).

  Returns `{:ok, {ip, range, source_changes}}` where `ip` is the parsed address,
  `range` is the masked address actually queried, and `source_changes` is a
  paginated set with its user and image associations preloaded.
  """
  @spec ip_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, {Postgrex.INET.t(), Postgrex.INET.t(), Scrivener.Page.t()}}
          | {:error, :unauthorized | :not_found}
  def ip_source_changes(%Actor{} = actor, ip, params, pagination) do
    with :ok <- authorize(actor, :show, :identity_metadata),
         {:ok, ip} <- cast_ip(ip) do
      range = IpMask.parse_mask(ip, params)

      source_changes =
        SourceChange
        |> where(fragment("? >>= ip", ^range))
        |> added_filter(params)
        |> order_by(desc: :id)
        |> preload([:user, image: [:user, :sources, tags: :aliases]])
        |> Repo.paginate(pagination)

      {:ok, {ip, range, source_changes}}
    end
  end

  @doc """
  Lists the source changes attributed to `fingerprint`, newest first, on behalf
  of `actor`.

  Listing is staff-only: a viewer who may not see IP addresses gets
  `{:error, :unauthorized}`. The fingerprint is matched as a raw string, so any
  value returns a (possibly empty) listing. `params["added"]` narrows to
  additions (`"1"`) or removals (`"0"`).

  Returns `{:ok, source_changes}`, a paginated set with its user and image
  associations preloaded.
  """
  @spec fingerprint_source_changes(Actor.t(), String.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def fingerprint_source_changes(%Actor{} = actor, fingerprint, params, pagination) do
    with :ok <- authorize(actor, :show, :identity_metadata) do
      source_changes =
        SourceChange
        |> where(fingerprint: ^fingerprint)
        |> added_filter(params)
        |> order_by(desc: :id)
        |> preload([:user, image: [:user, :sources, tags: :aliases]])
        |> Repo.paginate(pagination)

      {:ok, source_changes}
    end
  end

  defp cast_ip(ip) do
    case EctoNetwork.INET.cast(ip) do
      {:ok, ip} -> {:ok, ip}
      _error -> {:error, :not_found}
    end
  end

  defp added_filter(query, %{"added" => "1"}),
    do: where(query, added: true)

  defp added_filter(query, %{"added" => "0"}),
    do: where(query, added: false)

  defp added_filter(query, _params),
    do: query
end
