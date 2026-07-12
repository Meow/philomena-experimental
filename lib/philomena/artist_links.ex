defmodule Philomena.ArtistLinks do
  @moduledoc """
  The ArtistLinks context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.IntegerId
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Users.User
  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.ArtistLinks.AutomaticVerifier
  alias Philomena.ArtistLinks.BadgeAwarder
  alias Philomena.Tags

  @doc """
  Updates all artist links pending verification, by transitioning to link verified state
  or resetting next update time.
  """
  def automatic_verify! do
    Enum.each(AutomaticVerifier.generate_updates(), &Repo.update!/1)
  end

  @doc """
  Gets a single artist link.

  Raises `Ecto.NoResultsError` if the Artist link does not exist.

  ## Examples

      iex> get_artist_link!(123)
      %ArtistLink{}

      iex> get_artist_link!(456)
      ** (Ecto.NoResultsError)

  """
  def get_artist_link!(id), do: Repo.get!(ArtistLink, id)

  @doc """
  Lists the artist links belonging to the user named by the profile `slug`, on
  behalf of `actor`.

  The profile user is loaded by slug and authorized for `:create_links`; an
  unknown slug authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}` (`{:error, :not_found}` for viewers whose grants
  cover `nil`).

  Returns `{:ok, {user, artist_links}}`.
  """
  @spec list_artist_links(User.t() | nil, String.t()) ::
          {:ok, {User.t(), [ArtistLink.t()]}} | {:error, :unauthorized | :not_found}
  def list_artist_links(actor, slug) do
    with {:ok, user} <- authorized_profile(actor, :create_links, slug) do
      links =
        ArtistLink
        |> where(user_id: ^user.id)
        |> Repo.all()

      {:ok, {user, links}}
    end
  end

  @doc """
  Returns the paginated artist links for the admin listing, on behalf of
  `actor`, newest first, with the moderation-view associations preloaded.

  Authorizes `:index` against the artist link model. `params` selects the
  listing mode: `"all"` lists every link, `"lq"` filters by a `%term%` match on
  the profile user name or the link uri, and otherwise only links awaiting
  moderation (`unverified`/`link_verified`/`contacted`) are shown.

  Returns `{:ok, artist_links}` as a `m:Scrivener.Page` or
  `{:error, :unauthorized}`.
  """
  @spec load_artist_links_index(User.t() | nil, map(), map() | keyword()) ::
          {:ok, Scrivener.Page.t()} | {:error, :unauthorized}
  def load_artist_links_index(actor, params, pagination) do
    with :ok <- authorize(actor, :index, %ArtistLink{}) do
      artist_links =
        params
        |> index_query()
        |> order_by(desc: :created_at)
        |> preload([
          :tag,
          :verified_by_user,
          :contacted_by_user,
          user: [:linked_tags, awards: :badge]
        ])
        |> Repo.paginate(pagination)

      {:ok, artist_links}
    end
  end

  defp index_query(%{"all" => _value}) do
    ArtistLink
  end

  defp index_query(%{"lq" => query}) do
    query = "%#{query}%"

    ArtistLink
    |> join(:inner, [ul], _ in assoc(ul, :user))
    |> where([ul, u], ilike(u.name, ^query) or ilike(ul.uri, ^query))
  end

  defp index_query(_params) do
    where(ArtistLink, [ul], ul.aasm_state in ^["unverified", "link_verified", "contacted"])
  end

  @doc """
  Loads the profile user named by `slug` for the new artist link form, on behalf
  of `actor`.

  A banned actor is rejected first with `{:error, :ban}`. The profile user is
  then loaded by slug and authorized for `:create_links`.

  Returns `{:ok, {user, changeset}}`.
  """
  @spec load_artist_link_for_new(Actor.t(), String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_artist_link_for_new(%Actor{} = actor, slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, user} <- authorized_profile(actor.user, :create_links, slug) do
      {:ok, {user, change_artist_link(%ArtistLink{})}}
    end
  end

  @doc """
  Submits a new artist link for the user named by the profile `slug`, on behalf
  of `actor`, from the controller-shaped `attrs`.

  The actor's write access is verified first: a banned actor is `{:error, :ban}`
  and an actor with no fingerprint `{:error, :unauthorized}`. The profile user is
  then loaded by slug and authorized for `:create_links` before the link is
  inserted in the unverified state.

  Returns `{:ok, {user, artist_link}}` on success, or
  `{:error, {user, changeset}}` when the insert is rejected.
  """
  @spec create_artist_link(Actor.t(), String.t(), map()) ::
          {:ok, {User.t(), ArtistLink.t()}}
          | {:error, {User.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def create_artist_link(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- authorized_profile(actor.user, :create_links, slug) do
      case create_artist_link(user, attrs) do
        {:ok, artist_link} -> {:ok, {user, artist_link}}
        {:error, changeset} -> {:error, {user, changeset}}
      end
    end
  end

  @doc """
  Loads the artist link named by `id` under the profile `slug` for display, on
  behalf of `actor`.

  The link is loaded by id and authorized for `:show`; then the profile user is
  loaded by slug and authorized for `:create_links`. A non-castable or unknown
  id is `{:error, :not_found}`; a load the actor may not act on is
  `{:error, :unauthorized}`.

  Returns `{:ok, {user, artist_link}}`.
  """
  @spec load_artist_link_for_show(User.t() | nil, String.t(), String.t()) ::
          {:ok, {User.t(), ArtistLink.t()}} | {:error, :unauthorized | :not_found}
  def load_artist_link_for_show(actor, slug, id) do
    with {:ok, artist_link} <- authorized_artist_link(actor, :show, id),
         {:ok, user} <- authorized_profile(actor, :create_links, slug) do
      {:ok, {user, artist_link}}
    end
  end

  @doc """
  Loads the artist link named by `id` under the profile `slug` for editing, on
  behalf of `actor`.

  The link is loaded by id and authorized for `:edit`; then the profile user is
  loaded by slug and authorized for `:edit_links`. A non-castable or unknown id
  is `{:error, :not_found}`; a load the actor may not act on is
  `{:error, :unauthorized}`.

  Returns `{:ok, {artist_link, changeset}}`.
  """
  @spec load_artist_link_for_edit(User.t() | nil, String.t(), String.t()) ::
          {:ok, {ArtistLink.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def load_artist_link_for_edit(actor, slug, id) do
    with {:ok, artist_link} <- authorized_artist_link(actor, :edit, id),
         {:ok, _user} <- authorized_profile(actor, :edit_links, slug) do
      {:ok, {artist_link, change_artist_link(artist_link)}}
    end
  end

  # Loads a user by profile slug and authorizes the acting user for `action`.
  defp authorized_profile(actor, action, slug) do
    user = Repo.get_by(User, slug: slug)

    with :ok <- authorize(actor, action, user),
         %User{} <- user do
      {:ok, user}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  # Loads an artist link by id (with its form/display preloads) and authorizes
  # the acting user for `action`. A non-castable id, or a `nil` load the actor
  # was permitted to act on, is `{:error, :not_found}`.
  defp authorized_artist_link(actor, action, id) do
    with {:ok, id} <- IntegerId.parse(id),
         artist_link = load_artist_link_by_id(id),
         :ok <- authorize(actor, action, artist_link),
         %ArtistLink{} <- artist_link do
      {:ok, artist_link}
    else
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
  end

  defp load_artist_link_by_id(id) do
    ArtistLink
    |> where(id: ^id)
    |> preload([:user, :tag, :contacted_by_user])
    |> Repo.one()
  end

  @doc """
  Creates an artist link.

  ## Examples

      iex> create_artist_link(%{field: value})
      {:ok, %ArtistLink{}}

      iex> create_artist_link(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_artist_link(user, attrs \\ %{}) do
    tag = Tags.get_tag_or_alias_by_name(attrs["tag_name"])

    %ArtistLink{}
    |> ArtistLink.creation_changeset(attrs, user, tag)
    |> Repo.insert()
  end

  @doc """
  Updates the artist link named by `id` under the profile `slug`, on behalf of
  `actor`, from the controller-shaped `attrs`.

  The link is loaded by id and authorized for `:update`; then the profile user
  is loaded by slug and authorized for `:edit_links`. A non-castable or unknown
  id is `{:error, :not_found}`; a load the actor may not act on is
  `{:error, :unauthorized}`.

  Returns `{:ok, {user, artist_link}}` on success, or
  `{:error, {artist_link, changeset}}` when the update is rejected.
  """
  @spec update_artist_link(User.t() | nil, String.t(), String.t(), map()) ::
          {:ok, {User.t(), ArtistLink.t()}}
          | {:error, {ArtistLink.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def update_artist_link(actor, slug, id, attrs) do
    with {:ok, artist_link} <- authorized_artist_link(actor, :update, id),
         {:ok, user} <- authorized_profile(actor, :edit_links, slug) do
      case update_artist_link(artist_link, attrs) do
        {:ok, artist_link} -> {:ok, {user, artist_link}}
        {:error, changeset} -> {:error, {artist_link, changeset}}
      end
    end
  end

  @doc """
  Updates an artist link.

  ## Examples

      iex> update_artist_link(artist_link, %{field: new_value})
      {:ok, %ArtistLink{}}

      iex> update_artist_link(artist_link, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_artist_link(%ArtistLink{} = artist_link, attrs) do
    tag = Tags.get_tag_or_alias_by_name(attrs["tag_name"])

    artist_link
    |> ArtistLink.edit_changeset(attrs, tag)
    |> Repo.update()
  end

  @doc """
  Verifies the artist link named by `id`, on behalf of `actor`, transitioning it
  to the verified state and awarding the artist badge to its owner.

  The link is loaded by id and authorized for `:edit`: a non-castable or unknown
  id is `{:error, :not_found}`, and a load a moderator may not act on is
  `{:error, :unauthorized}`. On success a moderation log attributing the
  verification to `actor` is written.

  Returns `{:ok, artist_link}`.
  """
  @spec verify_artist_link(User.t() | nil, String.t()) ::
          {:ok, ArtistLink.t()} | {:error, :unauthorized | :not_found}
  def verify_artist_link(actor, id) do
    with {:ok, artist_link} <- authorized_artist_link(actor, :edit, id) do
      {:ok, artist_link} = verify_loaded_link(artist_link, actor)

      ModerationLogs.create_moderation_log(
        actor,
        "Admin.ArtistLink.Verification:create",
        Paths.artist_link_path(artist_link.user, artist_link),
        "Verified artist link #{artist_link.uri} created by #{artist_link.user.name}"
      )

      {:ok, artist_link}
    end
  end

  @doc """
  Transitions an artist link to the verified state.

  ## Examples

      iex> verify_loaded_link(artist_link, verifying_user)
      {:ok, %ArtistLink{}}

      iex> verify_loaded_link(artist_link, verifying_user)
      :error

  """
  def verify_loaded_link(%ArtistLink{} = artist_link, verifying_user) do
    artist_link_changeset = ArtistLink.verify_changeset(artist_link, verifying_user)

    Multi.new()
    |> Multi.update(:artist_link, artist_link_changeset)
    |> Multi.run(:add_award, BadgeAwarder.award_callback(artist_link, verifying_user))
    |> Repo.transaction()
    |> case do
      {:ok, %{artist_link: artist_link}} ->
        {:ok, artist_link}

      {:error, _operation, _value, _changes} ->
        :error
    end
  end

  @doc """
  Transitions an artist link to the rejected state.

  ## Examples

      iex> reject_artist_link(artist_link)
      {:ok, %ArtistLink{}}

      iex> reject_artist_link(artist_link)
      {:error, %Ecto.Changeset{}}

  """
  def reject_artist_link(%ArtistLink{} = artist_link) do
    artist_link
    |> ArtistLink.reject_changeset()
    |> Repo.update()
  end

  @doc """
  Transitions an artist link to the contacted state.

  ## Examples

      iex> contact_artist_link(artist_link)
      {:ok, %ArtistLink{}}

      iex> contact_artist_link(artist_link)
      {:error, %Ecto.Changeset{}}

  """
  def contact_artist_link(%ArtistLink{} = artist_link, user) do
    artist_link
    |> ArtistLink.contact_changeset(user)
    |> Repo.update()
  end

  @doc """
  Deletes an artist link.

  ## Examples

      iex> delete_artist_link(artist_link)
      {:ok, %ArtistLink{}}

      iex> delete_artist_link(artist_link)
      {:error, %Ecto.Changeset{}}

  """
  def delete_artist_link(%ArtistLink{} = artist_link) do
    Repo.delete(artist_link)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking artist link changes.

  ## Examples

      iex> change_artist_link(artist_link)
      %Ecto.Changeset{source: %ArtistLink{}}

  """
  def change_artist_link(%ArtistLink{} = artist_link) do
    ArtistLink.changeset(artist_link, %{})
  end

  @doc """
  Counts the number of artist links which are pending moderation action, or
  nil if the user is not permitted to moderate artist links.

  ## Examples

      iex> count_artist_links(normal_user)
      nil

      iex> count_artist_links(admin_user)
      0

  """
  def count_artist_links(user) do
    if Canada.Can.can?(user, :index, %ArtistLink{}) do
      ArtistLink
      |> where([ul], ul.aasm_state in ^["unverified", "link_verified"])
      |> Repo.aggregate(:count)
    else
      nil
    end
  end
end
