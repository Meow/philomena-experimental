defmodule Philomena.Adverts do
  @moduledoc """
  The Adverts context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Attribution.Actor
  alias Philomena.ModerationLogs
  alias Philomena.Adverts.Advert
  alias Philomena.Adverts.Restrictions
  alias Philomena.Adverts.Server
  alias Philomena.Adverts.Uploader

  @doc """
  Gets a single advert.

  ## Examples

      iex> get_advert(123)
      {:ok, %Advert{}}

      iex> get_advert("123")
      {:ok, %Advert{}}

      iex> get_advert(456)
      {:error, :not_found}

  """
  @spec get_advert(Loader.integer_id()) :: {:ok, Advert.t()} | {:error, :not_found}
  def get_advert(id) do
    Loader.fetch(Advert, id)
  end

  # Creates an advert with an image.
  defp create_advert(attrs) do
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

  # Updates an Advert without updating its image.
  defp update_advert(%Advert{} = advert, attrs) do
    advert
    |> Advert.changeset(attrs)
    |> Repo.update()
  end

  # Updates the image for an Advert.
  defp update_advert_image(%Advert{} = advert, attrs) do
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

  # Deletes an Advert.
  defp delete_advert(%Advert{} = advert) do
    Repo.delete(advert)
  end

  # Returns an `%Ecto.Changeset{}` for tracking advert changes.
  defp change_advert(%Advert{} = advert) do
    Advert.changeset(advert, %{})
  end

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
  Returns paginated adverts for the admin listing, on behalf of `actor`,
  newest finish date first.

  ## Examples

      iex> load_adverts(admin, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_adverts(user, pagination)
      {:error, :unauthorized}

  """
  @spec load_adverts(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(Advert.t())} | {:error, :unauthorized}
  def load_adverts(%Actor{} = actor, pagination) do
    with :ok <- authorize(actor, :index, Advert) do
      adverts =
        Advert
        |> order_by(desc: :finish_date)
        |> Repo.paginate(pagination)

      {:ok, adverts}
    end
  end

  @doc """
  Builds the changeset for a new advert, on behalf of `actor`.

  Returns an `%Ecto.Changeset{}` for tracking advert changes.

  ## Examples

      iex> new_advert(admin)
      {:ok, %Ecto.Changeset{}}

      iex> new_advert(user)
      {:error, :unauthorized}

  """
  @spec new_advert(Actor.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_advert(%Actor{} = actor) do
    with :ok <- authorize(actor, :index, Advert) do
      {:ok, change_advert(%Advert{})}
    end
  end

  @doc """
  Creates an advert with an image, on behalf of `actor`.

  On success a moderation log attributing the creation to `actor` is written.

  ## Examples

      iex> create_advert(admin, advert_params)
      {:ok, %Advert{}}

      iex> create_advert(user, advert_params)
      {:error, :unauthorized}

  """
  @spec create_advert(Actor.t(), map()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_advert(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- create_advert(attrs) do
      advert_log(actor, :create, advert)
      {:ok, advert}
    end
  end

  @doc """
  Loads the advert named by the `id` for editing, on behalf of
  `actor`, pairing it with a change-tracking changeset.

  ## Examples

      iex> load_advert_for_edit(admin, advert_id)
      {:ok, {%Advert{}, %Ecto.Changeset{}}}

      iex> load_advert_for_edit(admin, invalid_id)
      {:error, :not_found}

      iex> load_advert_for_edit(user, advert_id)
      {:error, :unauthorized}

  """
  @spec load_advert_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Advert.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_advert_for_edit(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :edit, id) do
      {:ok, {advert, change_advert(advert)}}
    end
  end

  @doc """
  Updates the advert named by the `id` without touching its image,
  on behalf of `actor`.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_advert(admin, advert_id, advert_params)
      {:ok, %Advert{}}

      iex> update_advert(admin, advert_id, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_advert(admin, invalid_id, advert_params)
      {:error, :not_found}

      iex> update_advert(user, advert_id, advert_params)
      {:error, :unauthorized}

  """
  @spec update_advert(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_advert(%Actor{} = actor, id, attrs) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :update, id),
         {:ok, advert} <- update_advert(advert, attrs) do
      advert_log(actor, :update, advert)
      {:ok, advert}
    end
  end

  @doc """
  Deletes the advert named by the `id`, on behalf of `actor`.

  On success a moderation log attributing the deletion to `actor` is written.

  ## Examples

      iex> delete_advert(admin, advert_id)
      {:ok, %Advert{}}

      iex> delete_advert(admin, invalid_id)
      {:error, :not_found}

      iex> delete_advert(user, advert_id)
      {:error, :unauthorized}

  """
  @spec delete_advert(Actor.t(), Loader.integer_id()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | :not_found}
  def delete_advert(%Actor{} = actor, id) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :delete, id) do
      {:ok, advert} = delete_advert(advert)
      advert_log(actor, :delete, advert)
      {:ok, advert}
    end
  end

  @doc """
  Updates the image of the advert named by the `id`, on behalf of
  `actor`, running the image upload pipeline.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> update_advert_image(admin, advert_id, advert_params)
      {:ok, %Advert{}}

      iex> update_advert_image(admin, advert_id, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_advert_image(admin, invalid_id, advert_params)
      {:error, :not_found}

      iex> update_advert_image(user, advert_id, advert_params)
      {:error, :unauthorized}

  """
  @spec update_advert_image(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Advert.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_advert_image(%Actor{} = actor, id, attrs) do
    with :ok <- authorize(actor, :index, Advert),
         {:ok, advert} <- authorized_advert(actor, :update, id),
         {:ok, advert} <- update_advert_image(advert, attrs) do
      # TODO: it would change the log contents but this can realistically just be
      # folded into advert_log
      ModerationLogs.create_moderation_log(
        actor,
        "Admin.Advert.Image:update",
        "/admin/adverts",
        "Updated image for advert #{advert.id}"
      )

      {:ok, advert}
    end
  end

  # Loads an advert by id and authorizes `action` against it.
  @spec authorized_advert(Loader.actor(), atom(), Loader.integer_id()) ::
          Loader.fetch_and_authorize_result(Advert.t())
  defp authorized_advert(actor, action, id) do
    Loader.fetch_and_authorize(Advert, actor, action, id)
  end

  @spec advert_log(Loader.actor(), atom(), Advert.t()) :: any()
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
