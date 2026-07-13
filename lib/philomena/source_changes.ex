defmodule Philomena.SourceChanges do
  @moduledoc """
  The SourceChanges context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.IntegerId
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
  first, on behalf of `actor` (a user, or `nil` for an anonymous visitor).

  The image is loaded by id and authorized for `:show`. A non-castable or
  out-of-range id is `{:error, :not_found}`. A well-formed but unknown id is
  authorized as a `nil` load: an actor who may not `:show` it gets
  `{:error, :unauthorized}`, while an actor permitted to act on the `nil` load
  gets `{:error, :not_found}`. `pagination` is Scrivener pagination data passed
  through to `Repo.paginate/2`.

  Returns `{:ok, {image, source_changes}}` where `source_changes` is a paginated
  set with its user and image associations preloaded.

  ## Examples

      iex> image_source_changes(user, "42", page: 1, page_size: 25)
      {:ok, {%Image{}, %Scrivener.Page{}}}

      iex> image_source_changes(user, "999999999", page: 1, page_size: 25)
      {:error, :unauthorized}

  """
  @spec image_source_changes(User.t() | nil, String.t() | integer(), keyword() | map()) ::
          {:ok, {Image.t(), Scrivener.Page.t()}}
          | {:error, :unauthorized | :not_found}
  def image_source_changes(actor, image_id, pagination) do
    with {:ok, id} <- IntegerId.parse(image_id),
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
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  @doc """
  Lists the source changes made by the user named by the profile `slug`, newest
  first, on behalf of `actor` (a user, or `nil` for an anonymous visitor).

  The user is loaded by slug and authorized for `:show`; an unknown slug
  authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for viewers whose grants
  cover `nil`). Changes to the user's own anonymous uploads are excluded.
  `params["added"]` narrows to additions (`"1"`) or removals (`"0"`);
  `pagination` is Scrivener pagination data passed through to `Repo.paginate/2`.

  Returns `{:ok, {user, source_changes, image_count}}` where `source_changes` is
  a paginated set with its user and image associations preloaded
  and `image_count` is the number of distinct images touched.

  ## Examples

      iex> user_source_changes(actor, "artist", %{}, page: 1, page_size: 25)
      {:ok, {%User{}, %Scrivener.Page{}, 3}}

  """
  @spec user_source_changes(User.t() | nil, String.t(), map(), keyword() | map()) ::
          {:ok, {User.t(), Scrivener.Page.t(), non_neg_integer()}}
          | {:error, :unauthorized | :not_found}
  def user_source_changes(actor, slug, params, pagination) do
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
  behalf of `actor` (the current viewer).

  Listing is staff-only: a viewer who may not see IP addresses gets
  `{:error, :unauthorized}` before the address is parsed, matching the order the
  authorization gate runs in. An unparsable address is `{:error, :not_found}`.
  `params["mask"]` widens the query to a subnet; `params["added"]` narrows to
  additions (`"1"`) or removals (`"0"`); `pagination` is passed to
  `Repo.paginate/2`.

  Returns `{:ok, {ip, range, source_changes}}` where `ip` is the parsed address,
  `range` is the masked address actually queried, and `source_changes` is a
  paginated set with its user and image associations preloaded.
  """
  @spec ip_source_changes(User.t() | nil, String.t(), map(), keyword() | map()) ::
          {:ok, {Postgrex.INET.t(), Postgrex.INET.t(), Scrivener.Page.t()}}
          | {:error, :unauthorized | :not_found}
  def ip_source_changes(actor, ip, params, pagination) do
    with :ok <- authorize(actor, :show, :ip_address),
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
  of `actor` (the current viewer).

  Listing is staff-only: a viewer who may not see IP addresses gets
  `{:error, :unauthorized}`. The fingerprint is matched as a raw string, so any
  value returns a (possibly empty) listing. `params["added"]` narrows to
  additions (`"1"`) or removals (`"0"`); `pagination` is passed to
  `Repo.paginate/2`.

  Returns `{:ok, source_changes}`, a paginated set with its user and image
  associations preloaded.
  """
  @spec fingerprint_source_changes(User.t() | nil, String.t(), map(), keyword() | map()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def fingerprint_source_changes(actor, fingerprint, params, pagination) do
    with :ok <- authorize(actor, :show, :ip_address) do
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

  @doc """
  Gets a single source_change.

  Raises `Ecto.NoResultsError` if the Source change does not exist.

  ## Examples

      iex> get_source_change!(123)
      %SourceChange{}

      iex> get_source_change!(456)
      ** (Ecto.NoResultsError)

  """
  def get_source_change!(id), do: Repo.get!(SourceChange, id)

  @doc """
  Creates a source_change.

  ## Examples

      iex> create_source_change(%{field: value})
      {:ok, %SourceChange{}}

      iex> create_source_change(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_source_change(attrs \\ %{}) do
    %SourceChange{}
    |> SourceChange.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a source_change.

  ## Examples

      iex> update_source_change(source_change, %{field: new_value})
      {:ok, %SourceChange{}}

      iex> update_source_change(source_change, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_source_change(%SourceChange{} = source_change, attrs) do
    source_change
    |> SourceChange.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a SourceChange.

  ## Examples

      iex> delete_source_change(source_change)
      {:ok, %SourceChange{}}

      iex> delete_source_change(source_change)
      {:error, %Ecto.Changeset{}}

  """
  def delete_source_change(%SourceChange{} = source_change) do
    Repo.delete(source_change)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking source_change changes.

  ## Examples

      iex> change_source_change(source_change)
      %Ecto.Changeset{source: %SourceChange{}}

  """
  def change_source_change(%SourceChange{} = source_change) do
    SourceChange.changeset(source_change, %{})
  end
end
