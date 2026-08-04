defmodule Philomena.Adverts do
  @moduledoc """
  Public advert selection and click/impression tracking, plus actor-scoped
  advert administration.

  Public selection and recording are deliberately unauthenticated. Admin form
  and mutation APIs enforce the global write prerequisite and action-specific
  abilities; member paths load before authorizing the real advert.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Adverts.{Advert, Restrictions, Server, Uploader}
  alias Philomena.Attribution.Actor
  alias Philomena.Authorization
  alias Philomena.Images.Image
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.Repo

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

  defp random_live_for_tags(tags) do
    tags
    |> Restrictions.tags()
    |> live_adverts_query()
    |> order_by(asc: fragment("random()"))
    |> limit(1)
    |> Repo.one()
  end

  defp live_adverts_query(restrictions \\ nil) do
    now = DateTime.utc_now()

    query =
      Advert
      |> where(live: true)
      |> where([a], a.start_date < ^now and a.finish_date > ^now)

    if restrictions do
      where(query, [a], a.restrictions in ^restrictions)
    else
      query
    end
  end

  defp load_live_advert(id) do
    case IntegerId.parse(id) do
      {:ok, id} -> live_adverts_query() |> where(id: ^id) |> Loader.one()
      :error -> {:error, :not_found}
    end
  end

  defp load_advert(actor, action, id) do
    Loader.fetch_and_authorize(Advert, actor, action, id)
  end

  defp load_advert_change(actor, action, id) do
    with :ok <- verify_write_access(actor),
         {:ok, advert} <- load_advert(actor, action, id) do
      {:ok, {advert, change_advert(advert)}}
    end
  end

  defp transact_and_log(operation, actor, action) do
    Repo.transact(fn ->
      with {:ok, advert} <- operation.(),
           {:ok, _log} <- advert_log(actor, action, advert) do
        {:ok, advert}
      end
    end)
  end

  defp advert_log(actor, action, advert) do
    {type, body} =
      case action do
        :create -> {"Admin.Advert:create", "Created advert #{advert.id}"}
        :update -> {"Admin.Advert:update", "Updated advert #{advert.id}"}
        :update_image -> {"Admin.Advert.Image:update", "Updated image for advert #{advert.id}"}
        :delete -> {"Admin.Advert:delete", "Deleted advert #{advert.id}"}
      end

    ModerationLogs.create_moderation_log(actor, type, "/admin/adverts", body)
  end

  @doc """
  Gets an advert that is currently live.

  Returns the advert, or nil if nothing was live.

      iex> random_live()
      nil

      iex> random_live()
      %Advert{}

  """
  @spec random_live() :: Advert.t() | nil
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
  @spec random_live(Image.t()) :: Advert.t() | nil
  def random_live(image) do
    image
    |> Repo.preload(:tags)
    |> Map.get(:tags)
    |> Enum.map(& &1.name)
    |> random_live_for_tags()
  end

  @doc """
  Asynchronously records a new impression.

  ## Example

      iex> record_impression(%Advert{})
      :ok

  """
  @spec record_impression(Advert.t()) :: :ok
  def record_impression(%Advert{id: id}) do
    Server.record_impression(id)
  end

  @doc """
  Loads the currently live advert named by `id` and asynchronously records a
  click. Malformed, absent, disabled, not-yet-started, and expired adverts are
  not found.

  ## Example

      iex> record_click(advert.id)
      {:ok, %Advert{}}

  """
  @spec record_click(Loader.integer_id()) :: {:ok, Advert.t()} | {:error, :not_found}
  def record_click(id) do
    with {:ok, advert} <- load_live_advert(id),
         :ok <- Server.record_click(advert.id) do
      {:ok, advert}
    end
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
  @spec new_advert(Actor.t()) :: {:ok, Ecto.Changeset.t()} | Authorization.write_error()
  def new_advert(%Actor{} = actor) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, Advert) do
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
          {:ok, Advert.t()} | Authorization.write_error() | {:error, Ecto.Changeset.t()}
  def create_advert(%Actor{} = actor, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Advert) do
      transact_and_log(fn -> create_advert(attrs) end, actor, :create)
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
          {:ok, {Advert.t(), Ecto.Changeset.t()}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_advert_for_edit(%Actor{} = actor, id) do
    load_advert_change(actor, :edit, id)
  end

  @doc """
  Loads the advert named by `id` for the image edit form, on behalf of `actor`.
  The form authorizes the same `:update_image` action as its mutation.
  """
  @spec load_advert_for_image_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Advert.t(), Ecto.Changeset.t()}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_advert_for_image_edit(%Actor{} = actor, id) do
    load_advert_change(actor, :update_image, id)
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
          {:ok, Advert.t()}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def update_advert(%Actor{} = actor, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, advert} <- load_advert(actor, :update, id) do
      transact_and_log(fn -> update_advert(advert, attrs) end, actor, :update)
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
          {:ok, Advert.t()} | {:error, Authorization.write_error_reason() | :not_found}
  def delete_advert(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, advert} <- load_advert(actor, :delete, id) do
      transact_and_log(fn -> delete_advert(advert) end, actor, :delete)
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
          {:ok, Advert.t()}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def update_advert_image(%Actor{} = actor, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, advert} <- load_advert(actor, :update_image, id) do
      transact_and_log(fn -> update_advert_image(advert, attrs) end, actor, :update_image)
    end
  end
end
