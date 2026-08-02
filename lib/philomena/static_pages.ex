defmodule Philomena.StaticPages do
  @moduledoc """
  The StaticPages context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.StaticPages.StaticPage
  alias Philomena.StaticPages.Version

  # Returns the list of static pages.
  defp list_static_pages do
    Repo.all(StaticPage)
  end

  # Gets a single static page. Visible for testing.
  @doc false
  def get_static_page!(id), do: Repo.get!(StaticPage, id)

  # Creates a static_page. Visible for testing.
  @doc false
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

  # Updates a static page. Visible for testing.
  @doc false
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

  # Returns an `%Ecto.Changeset{}` for tracking static page changes.
  defp change_static_page(%StaticPage{} = static_page) do
    StaticPage.changeset(static_page, %{})
  end

  @doc """
  Returns the static pages listing on behalf of `actor`.

  The listing is staff-only. Returns `{:error, :unauthorized}` when the viewer
  may not manage static pages, otherwise `{:ok, static_pages}`.
  """
  @spec load_page_listing(Actor.t()) :: {:ok, [StaticPage.t()]} | {:error, :unauthorized}
  def load_page_listing(%Actor{} = actor) do
    with :ok <- authorize(actor, :index, StaticPage) do
      {:ok, list_static_pages()}
    end
  end

  @doc """
  Loads the static page named by `slug`, on behalf of `actor`.

  Returns `{:error, :not_found}` for an unknown slug the viewer may otherwise
  read, `{:error, :unauthorized}` when the viewer may not see it, and otherwise
  `{:ok, static_page}`. Individual pages are public.
  """
  @spec load_page_for_show(Actor.t(), String.t()) ::
          {:ok, StaticPage.t()} | {:error, :not_found | :unauthorized}
  def load_page_for_show(%Actor{} = actor, slug) do
    load_authorized_static_page(actor, slug, :show)
  end

  @doc """
  Loads the revision history for the static page named by `slug`.

  Returns `{:error, :not_found}` for an unknown slug. On success returns
  `{:ok, {static_page, versions}}`: the page and its versions newest first
  (ties broken by id), each with the acting user preloaded.
  """
  @spec load_page_history(String.t()) ::
          {:ok, {StaticPage.t(), [Version.t()]}} | {:error, :not_found}
  def load_page_history(slug) do
    case Repo.get_by(StaticPage, slug: slug) do
      nil ->
        {:error, :not_found}

      static_page ->
        versions =
          Version
          |> where(static_page_id: ^static_page.id)
          |> preload(:user)
          |> order_by(desc: :created_at, desc: :id)
          |> Repo.all()

        {:ok, {static_page, versions}}
    end
  end

  @doc """
  Prepares a new static page, on behalf of `actor`.

  Returns `{:error, :unauthorized}` when the viewer may not manage static pages,
  otherwise `{:ok, changeset}`.
  """
  @spec new_page(Actor.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_page(%Actor{} = actor) do
    with :ok <- authorize(actor, :new, StaticPage) do
      {:ok, change_static_page(%StaticPage{})}
    end
  end

  @doc """
  Creates a static page (with its initial version), on behalf of `actor`.

  Returns `{:error, :unauthorized}` when the viewer may not manage static pages,
  `{:error, :static_page, changeset, changes}` on a validation failure, and
  `{:ok, %{static_page: static_page, version: version}}` on success.
  """
  @spec create_page(Actor.t(), map()) ::
          {:ok, map()}
          | {:error, :static_page, Ecto.Changeset.t(), map()}
          | {:error, :unauthorized}
  def create_page(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :create, StaticPage) do
      create_static_page(actor.user, attrs)
    end
  end

  @doc """
  Loads the static page named by `slug` for edit, on behalf of `actor`.

  Returns `{:error, :not_found}` for an unknown slug the viewer may otherwise
  manage, `{:error, :unauthorized}` when the viewer may not edit static pages,
  and otherwise `{:ok, {static_page, changeset}}`.
  """
  @spec load_page_for_edit(Actor.t(), String.t()) ::
          {:ok, {StaticPage.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_page_for_edit(%Actor{} = actor, slug) do
    with {:ok, static_page} <- load_authorized_static_page(actor, slug, :edit) do
      {:ok, {static_page, change_static_page(static_page)}}
    end
  end

  @doc """
  Updates the static page named by `slug` (with a new version), on behalf of
  `actor`.

  Returns `{:error, :not_found}` for an unknown slug the viewer may otherwise
  manage, `{:error, :unauthorized}` when the viewer may not edit static pages,
  `{:error, :static_page, changeset, changes}` on a validation failure, and
  `{:ok, %{static_page: static_page, version: version}}` on success.
  """
  @spec update_page(Actor.t(), String.t(), map()) ::
          {:ok, map()}
          | {:error, :static_page, Ecto.Changeset.t(), map()}
          | {:error, :not_found | :unauthorized}
  def update_page(%Actor{} = actor, slug, attrs) do
    # TODO: maybe just return the static page instead of the multi result map on success here?
    with {:ok, static_page} <- load_authorized_static_page(actor, slug, :update) do
      update_static_page(static_page, actor.user, attrs)
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
