defmodule Philomena.SiteNotices do
  @moduledoc """
  The SiteNotices context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Attribution.Actor
  alias Philomena.Repo
  alias Philomena.Loader
  alias Philomena.SiteNotices.SiteNotice

  @doc """
  Returns the list of site_notices.

  ## Examples

      iex> list_site_notices()
      [%SiteNotice{}, ...]

  """
  def active_site_notices do
    now = DateTime.utc_now()

    SiteNotice
    |> where(live: true)
    |> where([n], n.start_date < ^now and n.finish_date > ^now)
    |> order_by(desc: :start_date)
    |> Repo.all()
  end

  @doc """
  Gets a single site_notice.

  Raises `Ecto.NoResultsError` if the Site notice does not exist.

  ## Examples

      iex> get_site_notice!(123)
      %SiteNotice{}

      iex> get_site_notice!(456)
      ** (Ecto.NoResultsError)

  """
  def get_site_notice!(id), do: Repo.get!(SiteNotice, id)

  @doc """
  Returns the paginated site notices for the admin listing, on behalf of
  `actor`, newest start date first.

  Authorizes `:index` against the site-notice model. Returns
  `{:ok, site_notices}` as a `m:Scrivener.Page` or `{:error, :unauthorized}`.
  """
  @spec load_site_notices(Actor.t(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_site_notices(%Actor{} = actor, pagination) do
    with :ok <- authorize(actor, :index, SiteNotice) do
      site_notices =
        SiteNotice
        |> order_by(desc: :start_date)
        |> Repo.paginate(pagination)

      {:ok, site_notices}
    end
  end

  @doc """
  Builds the changeset for a new site notice, on behalf of `actor`.

  Authorizes `:new` against the site-notice model. Returns `{:ok, changeset}` or
  `{:error, :unauthorized}`.
  """
  @spec new_site_notice(Actor.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_site_notice(%Actor{} = actor) do
    with :ok <- authorize(actor, :new, SiteNotice) do
      {:ok, change_site_notice(%SiteNotice{})}
    end
  end

  @doc """
  Creates a site notice on behalf of `actor`, whose user becomes its author.

  Authorizes `:create` against the site-notice model, then inserts the notice.
  Returns `{:ok, site_notice}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}`.

  ## Examples

      iex> create_site_notice(admin, %{field: value})
      {:ok, %SiteNotice{}}

      iex> create_site_notice(admin, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_site_notice(Actor.t(), map()) ::
          {:ok, SiteNotice.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_site_notice(%Actor{} = actor, attrs \\ %{}) do
    with :ok <- authorize(actor, :create, SiteNotice) do
      %SiteNotice{user_id: actor.user.id}
      |> SiteNotice.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Loads the site notice named by the `id` for editing, on behalf of
  `actor`, pairing it with a change-tracking changeset.

  Authorizes `:edit` against the loaded notice: a non-castable id is
  `{:error, :not_found}`, and an unknown id authorizes `nil` and comes back
  `{:error, :unauthorized}` for a non-admin (admins get `{:error, :not_found}`).

  Returns `{:ok, {site_notice, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec load_site_notice_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {SiteNotice.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_site_notice_for_edit(%Actor{} = actor, id) do
    with {:ok, site_notice} <- load_site_notice(actor, id, :edit) do
      {:ok, {site_notice, change_site_notice(site_notice)}}
    end
  end

  @doc """
  Updates the site notice named by the `id`, on behalf of `actor`.

  Loading and authorization follow `load_site_notice_for_edit/2`, authorizing
  `:update`. Returns `{:ok, site_notice}`, `{:error, :unauthorized}`,
  `{:error, :not_found}`, or `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_site_notice(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, SiteNotice.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_site_notice(%Actor{} = actor, id, attrs) do
    with {:ok, site_notice} <- load_site_notice(actor, id, :update) do
      update_site_notice(site_notice, attrs)
    end
  end

  @doc """
  Updates a site_notice.

  ## Examples

      iex> update_site_notice(site_notice, %{field: new_value})
      {:ok, %SiteNotice{}}

      iex> update_site_notice(site_notice, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_site_notice(%SiteNotice{} = site_notice, attrs) do
    site_notice
    |> SiteNotice.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes the site notice named by the `id`, on behalf of `actor`.

  Loading and authorization follow `load_site_notice_for_edit/2`, authorizing
  `:delete`. Returns `{:ok, site_notice}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}`.
  """
  @spec delete_site_notice(Actor.t(), Loader.integer_id()) ::
          {:ok, SiteNotice.t()} | {:error, :unauthorized | :not_found}
  def delete_site_notice(%Actor{} = actor, id) do
    with {:ok, site_notice} <- load_site_notice(actor, id, :delete) do
      delete_site_notice(site_notice)
    end
  end

  @doc """
  Deletes a SiteNotice.

  ## Examples

      iex> delete_site_notice(site_notice)
      {:ok, %SiteNotice{}}

      iex> delete_site_notice(site_notice)
      {:error, %Ecto.Changeset{}}

  """
  def delete_site_notice(%SiteNotice{} = site_notice) do
    Repo.delete(site_notice)
  end

  # Loads the site notice named by the `id` and authorizes `action`
  # against it: a non-castable id or a `nil` load the actor was permitted to act
  # on (an admin) is `{:error, :not_found}`, while a `nil` or real notice the
  # actor may not act on is `{:error, :unauthorized}`.
  defp load_site_notice(actor, id, action) do
    Loader.fetch_and_authorize(SiteNotice, actor, action, id)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking site_notice changes.

  ## Examples

      iex> change_site_notice(site_notice)
      %Ecto.Changeset{source: %SiteNotice{}}

  """
  def change_site_notice(%SiteNotice{} = site_notice) do
    SiteNotice.changeset(site_notice, %{})
  end
end
