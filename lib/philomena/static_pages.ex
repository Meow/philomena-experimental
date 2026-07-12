defmodule Philomena.StaticPages do
  @moduledoc """
  The StaticPages context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.StaticPages.StaticPage
  alias Philomena.StaticPages.Version
  alias Philomena.Users.User

  @doc """
  Returns the list of static_pages.

  ## Examples

      iex> list_static_pages()
      [%StaticPage{}, ...]

  """
  def list_static_pages do
    Repo.all(StaticPage)
  end

  @doc """
  Gets a single static_page.

  Raises `Ecto.NoResultsError` if the Static page does not exist.

  ## Examples

      iex> get_static_page!(123)
      %StaticPage{}

      iex> get_static_page!(456)
      ** (Ecto.NoResultsError)

  """
  def get_static_page!(id), do: Repo.get!(StaticPage, id)

  @doc """
  Creates a static_page.

  ## Examples

      iex> create_static_page(%{field: value})
      {:ok, %StaticPage{}}

      iex> create_static_page(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_static_page(user, attrs \\ %{}) do
    static_page = StaticPage.changeset(%StaticPage{}, attrs)

    Multi.new()
    |> Multi.insert(:static_page, static_page)
    |> Multi.run(:version, fn repo, %{static_page: static_page} ->
      %Version{static_page_id: static_page.id, user_id: user.id}
      |> Version.changeset(attrs)
      |> repo.insert()
    end)
    |> Repo.transaction()
  end

  @doc """
  Updates a static_page.

  ## Examples

      iex> update_static_page(static_page, %{field: new_value})
      {:ok, %StaticPage{}}

      iex> update_static_page(static_page, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_static_page(%StaticPage{} = static_page, user, attrs) do
    version =
      %Version{static_page_id: static_page.id, user_id: user.id}
      |> Version.changeset(attrs)

    static_page =
      static_page
      |> StaticPage.changeset(attrs)

    Multi.new()
    |> Multi.update(:static_page, static_page)
    |> Multi.insert(:version, version)
    |> Repo.transaction()
  end

  @doc """
  Deletes a StaticPage.

  ## Examples

      iex> delete_static_page(static_page)
      {:ok, %StaticPage{}}

      iex> delete_static_page(static_page)
      {:error, %Ecto.Changeset{}}

  """
  def delete_static_page(%StaticPage{} = static_page) do
    Repo.delete(static_page)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking static_page changes.

  ## Examples

      iex> change_static_page(static_page)
      %Ecto.Changeset{source: %StaticPage{}}

  """
  def change_static_page(%StaticPage{} = static_page) do
    StaticPage.changeset(static_page, %{})
  end

  @doc """
  Returns the static pages for the index on behalf of `user`.

  The index is staff-only. Returns `{:error, :unauthorized}` when the viewer may
  not manage static pages, otherwise `{:ok, static_pages}`.
  """
  @spec load_page_listing(User.t() | nil) :: {:ok, [StaticPage.t()]} | {:error, :unauthorized}
  def load_page_listing(user) do
    with :ok <- authorize(user, :index, StaticPage) do
      {:ok, list_static_pages()}
    end
  end

  @doc """
  Loads the static page named by `slug` for `user` (the current viewer, possibly
  `nil`) to be shown.

  Returns `{:error, :not_found}` for an unknown slug the viewer may otherwise
  read, `{:error, :unauthorized}` when the viewer may not see it, and otherwise
  `{:ok, static_page}`. Individual pages are public.
  """
  @spec load_page_for_show(User.t() | nil, String.t()) ::
          {:ok, StaticPage.t()} | {:error, :not_found | :unauthorized}
  def load_page_for_show(user, slug) do
    load_authorized_static_page(user, slug, :show)
  end

  @doc """
  Prepares the new-page form on behalf of `user`.

  Returns `{:error, :unauthorized}` when the viewer may not manage static pages,
  otherwise `{:ok, changeset}`.
  """
  @spec new_page(User.t() | nil) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_page(user) do
    with :ok <- authorize(user, :new, StaticPage) do
      {:ok, change_static_page(%StaticPage{})}
    end
  end

  @doc """
  Creates a static page (with its initial version) on behalf of `user` from
  `attrs`.

  Returns `{:error, :unauthorized}` when the viewer may not manage static pages,
  `{:error, :static_page, changeset, changes}` on a validation failure, and
  `{:ok, %{static_page: static_page, version: version}}` on success.
  """
  @spec create_page(User.t() | nil, map()) ::
          {:ok, map()}
          | {:error, :static_page, Ecto.Changeset.t(), map()}
          | {:error, :unauthorized}
  def create_page(user, attrs) do
    with :ok <- authorize(user, :create, StaticPage) do
      create_static_page(user, attrs)
    end
  end

  @doc """
  Loads the static page named by `slug` for `user` to be edited.

  Returns `{:error, :not_found}` for an unknown slug the viewer may otherwise
  manage, `{:error, :unauthorized}` when the viewer may not edit static pages,
  and otherwise `{:ok, {static_page, changeset}}`.
  """
  @spec load_page_for_edit(User.t() | nil, String.t()) ::
          {:ok, {StaticPage.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_page_for_edit(user, slug) do
    with {:ok, static_page} <- load_authorized_static_page(user, slug, :edit) do
      {:ok, {static_page, change_static_page(static_page)}}
    end
  end

  @doc """
  Updates the static page named by `slug` (with a new version) on behalf of
  `user` from `attrs`.

  Returns `{:error, :not_found}` for an unknown slug the viewer may otherwise
  manage, `{:error, :unauthorized}` when the viewer may not edit static pages,
  `{:error, :static_page, changeset, changes}` on a validation failure, and
  `{:ok, %{static_page: static_page, version: version}}` on success.
  """
  @spec update_page(User.t() | nil, String.t(), map()) ::
          {:ok, map()}
          | {:error, :static_page, Ecto.Changeset.t(), map()}
          | {:error, :not_found | :unauthorized}
  def update_page(user, slug, attrs) do
    with {:ok, static_page} <- load_authorized_static_page(user, slug, :update) do
      update_static_page(static_page, user, attrs)
    end
  end

  # Loads and authorizes the page named by `slug` for `action`. Authorization
  # runs against the loaded record, nil included, before the not-found decision:
  # an unknown slug the viewer may not act on comes back unauthorized, and one it
  # may act on comes back not-found.
  defp load_authorized_static_page(user, slug, action) do
    static_page = Repo.get_by(StaticPage, slug: slug)

    with :ok <- authorize(user, action, static_page) do
      case static_page do
        nil -> {:error, :not_found}
        static_page -> {:ok, static_page}
      end
    end
  end
end
