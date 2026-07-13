defmodule Philomena.Adverts do
  @moduledoc """
  The Adverts context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.IntegerId
  alias Philomena.ModerationLogs
  alias Philomena.Users.User
  alias Philomena.Adverts.Advert
  alias Philomena.Adverts.Restrictions
  alias Philomena.Adverts.Server
  alias Philomena.Adverts.Uploader

  @doc """
  Gets an advert that is currently live.

  Returns the advert, or nil if nothing was live.

      iex> random_live()
      nil

      iex> random_live()
      %Advert{}

  """
  def random_live do
    random_live_for_tags([])
  end

  @doc """
  Gets an advert that is currently live, matching any tagging restrictions
  for the given image.

  Returns the advert, or nil if nothing was live.

  ## Examples

      iex> random_live(%Image{})
      nil

      iex> random_live(%Image{})
      %Advert{}

  """
  def random_live(image) do
    image
    |> Repo.preload(:tags)
    |> Map.get(:tags)
    |> Enum.map(& &1.name)
    |> random_live_for_tags()
  end

  defp random_live_for_tags(tags) do
    now = DateTime.utc_now()
    restrictions = Restrictions.tags(tags)

    query =
      from a in Advert,
        where: a.live == true,
        where: a.restrictions in ^restrictions,
        where: a.start_date < ^now and a.finish_date > ^now,
        order_by: [asc: fragment("random()")],
        limit: 1

    Repo.one(query)
  end

  @doc """
  Asynchronously records a new impression.

  ## Example

      iex> record_impression(%Advert{})
      :ok

  """
  def record_impression(%Advert{id: id}) do
    Server.record_impression(id)
  end

  @doc """
  Asynchronously records a new click.

  ## Example

      iex> record_click(%Advert{})
      :ok

  """
  def record_click(%Advert{id: id}) do
    Server.record_click(id)
  end

  @doc """
  Gets a single advert.

  Raises `Ecto.NoResultsError` if the Advert does not exist.

  ## Examples

      iex> get_advert!(123)
      %Advert{}

      iex> get_advert!(456)
      ** (Ecto.NoResultsError)

  """
  def get_advert!(id), do: Repo.get!(Advert, id)

  @doc """
  Loads the advert named by the raw request `id` for a click-through redirect.

  An id that cannot name a row - one that is not a well-formed integer, or that
  names no advert - is `{:error, :not_found}`; otherwise `{:ok, advert}`.
  """
  @spec get_advert(any()) :: {:ok, Advert.t()} | {:error, :not_found}
  def get_advert(id) do
    with {:ok, id} <- IntegerId.parse(id),
         %Advert{} = advert <- Repo.get(Advert, id) do
      {:ok, advert}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Creates an advert.

  ## Examples

      iex> create_advert(%{field: value})
      {:ok, %Advert{}}

      iex> create_advert(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_advert(attrs \\ %{}) do
    %Advert{}
    |> Advert.changeset(attrs)
    |> Uploader.analyze_upload(attrs)
    |> Repo.insert()
    |> case do
      {:ok, advert} ->
        Uploader.persist_upload(advert)
        Uploader.unpersist_old_upload(advert)

        {:ok, advert}

      error ->
        error
    end
  end

  @doc """
  Updates an Advert without updating its image.

  ## Examples

      iex> update_advert(advert, %{field: new_value})
      {:ok, %Advert{}}

      iex> update_advert(advert, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_advert(%Advert{} = advert, attrs) do
    advert
    |> Advert.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the image for an Advert.

  ## Examples

      iex> update_advert_image(advert, %{image: new_value})
      {:ok, %Advert{}}

      iex> update_advert_image(advert, %{image: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_advert_image(%Advert{} = advert, attrs) do
    advert
    |> Advert.changeset(attrs)
    |> Uploader.analyze_upload(attrs)
    |> Repo.update()
    |> case do
      {:ok, advert} ->
        Uploader.persist_upload(advert)
        Uploader.unpersist_old_upload(advert)

        {:ok, advert}

      error ->
        error
    end
  end

  @doc """
  Deletes an Advert.

  ## Examples

      iex> delete_advert(advert)
      {:ok, %Advert{}}

      iex> delete_advert(advert)
      {:error, %Ecto.Changeset{}}

  """
  def delete_advert(%Advert{} = advert) do
    Repo.delete(advert)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking advert changes.

  ## Examples

      iex> change_advert(advert)
      %Ecto.Changeset{source: %Advert{}}

  """
  def change_advert(%Advert{} = advert) do
    Advert.changeset(advert, %{})
  end

  @doc """
  Returns the paginated adverts for the admin listing, on behalf of `actor`,
  newest finish date first.

  Authorizes advert administration. Returns `{:ok, adverts}` as a
  `m:Scrivener.Page` or `{:error, :unauthorized}`.
  """
  @spec load_adverts(User.t() | nil, map() | keyword()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_adverts(actor, pagination) do
    with :ok <- authorize(actor, :index, Advert) do
      adverts =
        Advert
        |> order_by(desc: :finish_date)
        |> Repo.paginate(pagination)

      {:ok, adverts}
    end
  end

  @doc """
  Builds the changeset backing the new-advert form, on behalf of `actor`.

  Authorizes advert administration. Returns `{:ok, changeset}` or
  `{:error, :unauthorized}`.
  """
  @spec new_advert(User.t() | nil) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_advert(actor) do
    with :ok <- authorize(actor, :index, Advert) do
      {:ok, change_advert(%Advert{})}
    end
  end

  @doc """
  Creates an advert on behalf of `actor`, running the image upload pipeline.

  Authorizes advert administration, then inserts the advert. On success a
  moderation log attributing the creation to `actor` is written. Returns
  `{:ok, advert}`, `{:error, :unauthorized}`, or `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_advert(User.t() | nil, map()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_advert(actor, attrs) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- create_advert(attrs) do
      advert_log(actor, :create, advert)
      {:ok, advert}
    end
  end

  @doc """
  Loads the advert named by the raw request `id` for editing, on behalf of
  `actor`, pairing it with the changeset backing the edit form.

  Authorizes advert administration, then loads and authorizes the advert for
  `:edit`. A non-castable or unknown id is `{:error, :not_found}`; a load a
  moderator may not act on is `{:error, :unauthorized}`. Returns
  `{:ok, {advert, changeset}}` or `{:error, :unauthorized | :not_found}`.
  """
  @spec load_advert_for_edit(User.t() | nil, any()) ::
          {:ok, {Advert.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_advert_for_edit(actor, id) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :edit, id) do
      {:ok, {advert, change_advert(advert)}}
    end
  end

  @doc """
  Updates the advert named by the raw request `id` without touching its image,
  on behalf of `actor`.

  Authorizes advert administration, then loads and authorizes the advert for
  `:update`. A non-castable or unknown id is `{:error, :not_found}`; a load a
  moderator may not act on is `{:error, :unauthorized}`. On success a moderation
  log attributing the change to `actor` is written. Returns `{:ok, advert}`,
  `{:error, :unauthorized}`, `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_advert(User.t() | nil, any(), map()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_advert(actor, id, attrs) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :update, id),
         {:ok, advert} <- update_advert(advert, attrs) do
      advert_log(actor, :update, advert)
      {:ok, advert}
    end
  end

  @doc """
  Deletes the advert named by the raw request `id`, on behalf of `actor`.

  Authorizes advert administration, then loads and authorizes the advert for
  `:delete`. A non-castable or unknown id is `{:error, :not_found}`; a load a
  moderator may not act on is `{:error, :unauthorized}`. On success a moderation
  log attributing the deletion to `actor` is written. Returns `{:ok, advert}` or
  `{:error, :unauthorized | :not_found}`.
  """
  @spec delete_advert(User.t() | nil, any()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | :not_found}
  def delete_advert(actor, id) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :delete, id) do
      {:ok, advert} = delete_advert(advert)
      advert_log(actor, :delete, advert)
      {:ok, advert}
    end
  end

  @doc """
  Updates the image of the advert named by the raw request `id`, on behalf of
  `actor`, running the image upload pipeline.

  Authorizes advert administration, then loads and authorizes the advert for
  `:update`. A non-castable or unknown id is `{:error, :not_found}`; a load a
  moderator may not act on is `{:error, :unauthorized}`. On success a moderation
  log attributing the change to `actor` is written. Returns `{:ok, advert}`,
  `{:error, :unauthorized}`, `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_advert_image(User.t() | nil, any(), map()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_advert_image(actor, id, attrs) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :update, id),
         {:ok, advert} <- update_advert_image(advert, attrs) do
      ModerationLogs.create_moderation_log(
        actor,
        "Admin.Advert.Image:update",
        "/admin/adverts",
        "Updated image for advert #{advert.id}"
      )

      {:ok, advert}
    end
  end

  # Loads an advert by a raw request id and authorizes `action` against it: a
  # non-castable or unknown id is `{:error, :not_found}`, and a load the actor
  # may not act on is `{:error, :unauthorized}` (an admin, who may act on the
  # `nil` load, gets `{:error, :not_found}`).
  defp authorized_advert(actor, action, id) do
    with {:ok, id} <- IntegerId.parse(id),
         advert = Repo.get(Advert, id),
         :ok <- authorize(actor, action, advert),
         %Advert{} <- advert do
      {:ok, advert}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      _ -> {:error, :not_found}
    end
  end

  defp advert_log(actor, action, advert) do
    body =
      case action do
        :create -> "Created advert #{advert.id}"
        :update -> "Updated advert #{advert.id}"
        :delete -> "Deleted advert #{advert.id}"
      end

    ModerationLogs.create_moderation_log(actor, "Admin.Advert:#{action}", "/admin/adverts", body)
  end
end
