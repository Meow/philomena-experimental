defmodule Philomena.ArtistLinks do
  @moduledoc """
  The ArtistLinks context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Attribution.Actor
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Users.User
  alias Philomena.ArtistLinks.ArtistLink
  alias Philomena.ArtistLinks.AutomaticVerifier
  alias Philomena.ArtistLinks.BadgeAwarder
  alias Philomena.Tags

  # TODO: the need to load a profile by slug in this module is a bit weird
  # Might want to push that little bit of extra logic back to the controller.

  # Creates an artist link. Visible for testing.
  @doc false
  def create_artist_link(user, attrs) do
    tag = Tags.get_tag_or_alias_by_name(attrs["tag_name"])

    %ArtistLink{}
    |> ArtistLink.creation_changeset(attrs, user, tag)
    |> Repo.insert()
  end

  # Updates an artist link.
  defp update_artist_link(%ArtistLink{} = artist_link, attrs) do
    tag = Tags.get_tag_or_alias_by_name(attrs["tag_name"])

    artist_link
    |> ArtistLink.edit_changeset(attrs, tag)
    |> Repo.update()
  end

  # Transitions an artist link to the verified state. Visible for testing.
  @doc false
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

  # Transitions an artist link to the rejected state.
  defp reject_loaded_link(%ArtistLink{} = artist_link) do
    artist_link
    |> ArtistLink.reject_changeset()
    |> Repo.update()
  end

  # Transitions an artist link to the contacted state.
  defp contact_loaded_link(%ArtistLink{} = artist_link, user) do
    artist_link
    |> ArtistLink.contact_changeset(user)
    |> Repo.update()
  end

  # Returns an `%Ecto.Changeset{}` for tracking artist link changes.
  defp change_artist_link(%ArtistLink{} = artist_link) do
    ArtistLink.changeset(artist_link, %{})
  end

  @doc """
  Updates all artist links pending verification, by transitioning to link verified state
  or resetting next update time.
  """
  def automatic_verify! do
    Enum.each(AutomaticVerifier.generate_updates(), &Repo.update!/1)
  end

  @doc """
  Lists the artist links belonging to the user named by the profile `slug`, on
  behalf of `actor`.

  ## Examples

      iex> list_artist_links(user, user.slug)
      {:ok, {%User{}, [%ArtistLink{}...]}}

      iex> list_artist_links(nil, user.slug)
      {:error, :unauthorized}

      iex> list_artist_links(user, invalid_slug)
      {:error, :not_found}

  """
  @spec list_artist_links(Loader.actor(), String.t()) ::
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
  Returns paginated artist links for the admin listing, on behalf of
  `actor`, newest first, with the moderation associations preloaded.

  `params` selects the listing mode:
  - Key `"all"` (value doesn't matter) lists every link
  - Key `"lq"` filters by `%term%` match on the profile user name or the link uri

  Otherwise, only links awaiting moderation
  (`unverified`/`link_verified`/`contacted`) are listed.

  ## Examples

      iex> load_artist_links_index(admin, params, pagination)
      {:ok, %Scrivener.Page{}}

      iex> load_artist_links_index(user, params, pagination)
      {:error, :unauthorized}

  """
  @spec load_artist_links_index(Loader.actor(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(ArtistLink.t())} | {:error, :unauthorized}
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
  Loads the profile user named by `slug` for creating a new artist link, on
  behalf of `actor`.

  ## Examples

      iex> load_artist_link_for_new(user, user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_artist_link_for_new(admin, other_user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_artist_link_for_new(banned_user, banned_user.slug)
      {:error, :ban}

      iex> load_artist_link_for_new(user, other_user.slug)
      {:error, :unauthorized}

      iex> load_artist_link_for_new(user, invalid_slug)
      {:error, :not_found}

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
  of `actor`, from `attrs`.

  ## Examples

      iex> create_artist_link(user, user.slug, artist_link_params)
      {:ok, {%User{}, %ArtistLink{}}}

      iex> create_artist_link(admin, other_user.slug, artist_link_params)
      {:ok, {%User{}, %ArtistLink{}}}

      iex> create_artist_link(user, user.slug, invalid_params)
      {:error, {%User{}, %Ecto.Changeset{}}}

      iex> create_artist_link(banned_user, banned_user.slug, artist_link_params)
      {:error, :ban}

      iex> create_artist_link(user, other_user.slug, artist_link_params)
      {:error, :unauthorized}

      iex> create_artist_link(user, invalid_slug, artist_link_params)
      {:error, :not_found}

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
  Loads the artist link named by `id` under the profile `slug`, on behalf of
  `actor`.

  ## Examples

      iex> load_artist_link_for_show(user, user.slug, artist_link_id)
      {:ok, {%User{}, %ArtistLink{}}}

      iex> load_artist_link_for_show(admin, other_user.slug, artist_link_id)
      {:ok, {%User{}, %ArtistLink{}}}

      iex> load_artist_link_for_show(user, other_user.slug, artist_link_id)
      {:error, :unauthorized}

      iex> load_artist_link_for_show(user, invalid_slug, invalid_id)
      {:error, :not_found}

  """
  @spec load_artist_link_for_show(Loader.actor(), String.t(), Loader.integer_id()) ::
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

  ## Examples

      iex> load_artist_link_for_edit(user, user.slug, artist_link_id)
      {:ok, {%ArtistLink{}, %Ecto.Changeset{}}}

      iex> load_artist_link_for_edit(admin, other_user.slug, artist_link_id)
      {:ok, {%ArtistLink{}, %Ecto.Changeset{}}}

      iex> load_artist_link_for_edit(user, other_user.slug, artist_link_id)
      {:error, :unauthorized}

      iex> load_artist_link_for_edit(user, invalid_slug, invalid_id)
      {:error, :not_found}

  """
  @spec load_artist_link_for_edit(Loader.actor(), String.t(), Loader.integer_id()) ::
          {:ok, {ArtistLink.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def load_artist_link_for_edit(actor, slug, id) do
    with {:ok, artist_link} <- authorized_artist_link(actor, :edit, id),
         {:ok, _user} <- authorized_profile(actor, :edit_links, slug) do
      {:ok, {artist_link, change_artist_link(artist_link)}}
    end
  end

  # Loads a user by profile slug and authorizes the acting user for `action`.
  @spec authorized_profile(Loader.actor(), atom(), String.t()) ::
          {:ok, User.t()} | {:error, :unauthorized | :not_found}
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

  # Loads an artist link by id (with its user, tag, and contacted-by preloads)
  # and authorizes the acting user for `action`.
  @spec authorized_artist_link(Loader.actor(), atom(), Loader.integer_id()) ::
          Loader.fetch_and_authorize_result(ArtistLink.t())
  defp authorized_artist_link(actor, action, id) do
    Loader.fetch_and_authorize(ArtistLink, actor, action, id, [
      :user,
      :tag,
      :contacted_by_user
    ])
  end

  @doc """
  Updates the artist link named by `id` under the profile `slug`, on behalf of
  `actor`, from `attrs`.

  TODO: the slug probably isn't needed here?

  ## Examples

      iex> update_artist_link(admin, user.slug, artist_link_id, artist_link_params)
      {:ok, {%User{}, %ArtistLink{}}}

      iex> update_artist_link(admin, user.slug, artist_link_id, invalid_params)
      {:error, {%ArtistLink{}, %Ecto.Changeset{}}}

      iex> update_artist_link(admin, user.slug, invalid_id, invalid_params)
      {:error, :not_found}

      iex> update_artist_link(user, user.slug, artist_link_id, artist_link_params)
      {:error, :unauthorized}

  """
  @spec update_artist_link(Loader.actor(), String.t(), Loader.integer_id(), map()) ::
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
  Verifies the artist link named by `id`, on behalf of `actor`, transitioning it
  to the verified state and awarding the artist badge to its owner.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> verify_artist_link(admin, artist_link_id)
      {:ok, %ArtistLink{}}

      iex> verify_artist_link(admin, invalid_id)
      {:error, :not_found}

      iex> verify_artist_link(user, artist_link_id)
      {:error, :unauthorized}

  """
  @spec verify_artist_link(Loader.actor(), Loader.integer_id()) ::
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
  Rejects the artist link named by `id`, on behalf of `actor`, transitioning it
  to the rejected state.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> reject_artist_link(admin, artist_link_id)
      {:ok, %ArtistLink{}}

      iex> reject_artist_link(admin, invalid_id)
      {:error, :not_found}

      iex> reject_artist_link(user, artist_link_id)
      {:error, :unauthorized}

  """
  @spec reject_artist_link(Loader.actor(), Loader.integer_id()) ::
          {:ok, ArtistLink.t()} | {:error, :unauthorized | :not_found}
  def reject_artist_link(actor, id) do
    with {:ok, artist_link} <- authorized_artist_link(actor, :edit, id) do
      {:ok, artist_link} = reject_loaded_link(artist_link)

      ModerationLogs.create_moderation_log(
        actor,
        "Admin.ArtistLink.Reject:create",
        Paths.artist_link_path(artist_link.user, artist_link),
        "Rejected artist link #{artist_link.uri} created by #{artist_link.user.name}"
      )

      {:ok, artist_link}
    end
  end

  @doc """
  Marks the artist link named by `id` as contacted, on behalf of `actor`,
  transitioning it to the contacted state.

  On success a moderation log attributing the update to `actor` is written.

  ## Examples

      iex> contact_artist_link(admin, artist_link_id)
      {:ok, %ArtistLink{}}

      iex> contact_artist_link(admin, invalid_id)
      {:error, :not_found}

      iex> contact_artist_link(user, artist_link_id)
      {:error, :unauthorized}

  """
  @spec contact_artist_link(Loader.actor(), Loader.integer_id()) ::
          {:ok, ArtistLink.t()} | {:error, :unauthorized | :not_found}
  def contact_artist_link(actor, id) do
    with {:ok, artist_link} <- authorized_artist_link(actor, :edit, id) do
      {:ok, artist_link} = contact_loaded_link(artist_link, actor)

      ModerationLogs.create_moderation_log(
        actor,
        "Admin.ArtistLink.Contact:create",
        Paths.artist_link_path(artist_link.user, artist_link),
        "Contacted artist #{artist_link.user.name} at #{artist_link.uri}"
      )

      {:ok, artist_link}
    end
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
