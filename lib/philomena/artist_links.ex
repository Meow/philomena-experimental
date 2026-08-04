defmodule Philomena.ArtistLinks do
  @moduledoc """
  Artist link submission and staff verification workflows.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  alias Philomena.ArtistLinks.{ArtistLink, AutomaticVerifier, BadgeAwarder}
  alias Philomena.Attribution.Actor
  alias Philomena.Authorization
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Repo
  alias Philomena.Tags
  alias Philomena.Users.User

  defp insert_artist_link(user, attrs) do
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

  defp verify_loaded_link(%ArtistLink{} = artist_link, verifying_user) do
    with {:ok, artist_link} <-
           artist_link
           |> ArtistLink.verify_changeset(verifying_user)
           |> Repo.update(),
         {:ok, _award} <- BadgeAwarder.award_badge(artist_link, verifying_user) do
      {:ok, artist_link}
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

  defp profile_query(slug) do
    User
    |> where(slug: ^slug)
    |> where([u], is_nil(u.deleted_at))
  end

  defp load_authorized_profile(actor, action, slug) do
    with {:ok, user} <- slug |> profile_query() |> Loader.one(),
         :ok <- authorize(actor, action, user) do
      {:ok, user}
    end
  end

  defp load_scoped_artist_link(actor, action, slug, id) do
    case IntegerId.parse(id) do
      {:ok, id} ->
        ArtistLink
        |> join(:inner, [al], user in assoc(al, :user))
        |> where([al, user], al.id == ^id and user.slug == ^slug and is_nil(user.deleted_at))
        |> preload([_al, user], user: user)
        |> preload([:tag, :contacted_by_user])
        |> Loader.one_and_authorize(actor, action)

      :error ->
        {:error, :not_found}
    end
  end

  defp load_artist_link(actor, action, id) do
    Loader.fetch_and_authorize(ArtistLink, actor, action, id, [
      :user,
      :tag,
      :contacted_by_user
    ])
  end

  defp transact_and_log(operation, log) do
    Repo.transact(fn ->
      with {:ok, artist_link} <- operation.(),
           {:ok, _log} <- log.(artist_link) do
        {:ok, artist_link}
      end
    end)
  end

  defp transition_log(actor, action, artist_link) do
    {type, body} =
      case action do
        :verify ->
          {"Admin.ArtistLink.Verification:create",
           "Verified artist link #{artist_link.uri} created by #{artist_link.user.name}"}

        :reject ->
          {"Admin.ArtistLink.Reject:create",
           "Rejected artist link #{artist_link.uri} created by #{artist_link.user.name}"}

        :contact ->
          {"Admin.ArtistLink.Contact:create",
           "Contacted artist #{artist_link.user.name} at #{artist_link.uri}"}
      end

    ModerationLogs.create_moderation_log(
      actor,
      type,
      Paths.artist_link_path(artist_link.user, artist_link),
      body
    )
  end

  @doc """
  Updates all artist links pending verification, by transitioning to link verified state
  or resetting next update time.

  This function is designed for automatic link verification as a background task,
  and is not intended for use from request-facing code.
  """
  @spec run_automatic_verification!() :: :ok
  def run_automatic_verification! do
    Enum.each(AutomaticVerifier.generate_updates(), &Repo.update!/1)
  end

  @doc """
  Lists the artist links belonging to the user named by the profile `slug`, on
  behalf of `actor`.

  ## Examples

      iex> list_artist_links(user_actor, user.slug)
      {:ok, {%User{}, [%ArtistLink{}, ...]}}

      iex> list_artist_links(anonymous_actor, user.slug)
      {:error, :unauthorized}

      iex> list_artist_links(user_actor, invalid_slug)
      {:error, :not_found}

  """
  @spec list_artist_links(Actor.t(), String.t()) ::
          {:ok, {User.t(), [ArtistLink.t()]}} | {:error, :unauthorized | :not_found}
  def list_artist_links(%Actor{} = actor, slug) do
    with {:ok, user} <- load_authorized_profile(actor, :create_links, slug) do
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
  @spec load_artist_links_index(Actor.t(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(ArtistLink.t())} | {:error, :unauthorized}
  def load_artist_links_index(%Actor{} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, ArtistLink) do
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

      iex> load_artist_link_for_new(user_actor, user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_artist_link_for_new(admin_actor, other_user.slug)
      {:ok, {%User{}, %Ecto.Changeset{}}}

      iex> load_artist_link_for_new(banned_actor, banned_user.slug)
      {:error, :ban}

      iex> load_artist_link_for_new(admin_actor, invalid_slug)
      {:error, :not_found}

      iex> load_artist_link_for_new(user_actor, other_user.slug)
      {:error, :unauthorized}

  """
  @spec load_artist_link_for_new(Actor.t(), String.t()) ::
          {:ok, {User.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_artist_link_for_new(%Actor{} = actor, slug) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_authorized_profile(actor, :create_links, slug) do
      {:ok, {user, change_artist_link(%ArtistLink{})}}
    end
  end

  @doc """
  Submits a new artist link for the user named by the profile `slug`, on behalf
  of `actor`, from `attrs`.

  ## Examples

      iex> create_artist_link(user_actor, user.slug, artist_link_params)
      {:ok, {%User{}, %ArtistLink{}}}

      iex> create_artist_link(admin_actor, other_user.slug, artist_link_params)
      {:ok, {%User{}, %ArtistLink{}}}

      iex> create_artist_link(user_actor, user.slug, invalid_params)
      {:error, {%User{}, %Ecto.Changeset{}}}

      iex> create_artist_link(banned_actor, banned_user.slug, artist_link_params)
      {:error, :ban}

      iex> create_artist_link(user_actor, other_user.slug, artist_link_params)
      {:error, :unauthorized}

      iex> create_artist_link(admin_actor, invalid_slug, artist_link_params)
      {:error, :not_found}

  """
  @spec create_artist_link(Actor.t(), String.t(), map()) ::
          {:ok, {User.t(), ArtistLink.t()}}
          | {:error, {User.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def create_artist_link(%Actor{} = actor, slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, user} <- load_authorized_profile(actor, :create_links, slug) do
      case insert_artist_link(user, attrs) do
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
  @spec load_artist_link_for_show(Actor.t(), String.t(), Loader.integer_id()) ::
          {:ok, {User.t(), ArtistLink.t()}} | {:error, :unauthorized | :not_found}
  def load_artist_link_for_show(%Actor{} = actor, slug, id) do
    with {:ok, artist_link} <- load_scoped_artist_link(actor, :show, slug, id) do
      {:ok, {artist_link.user, artist_link}}
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
  @spec load_artist_link_for_edit(Actor.t(), String.t(), Loader.integer_id()) ::
          {:ok, {ArtistLink.t(), Ecto.Changeset.t()}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def load_artist_link_for_edit(%Actor{} = actor, slug, id) do
    with :ok <- verify_write_access(actor),
         {:ok, artist_link} <- load_scoped_artist_link(actor, :edit, slug, id) do
      {:ok, {artist_link, change_artist_link(artist_link)}}
    end
  end

  @doc """
  Updates the artist link named by `id` under the profile `slug`, on behalf of
  `actor`, from `attrs`.

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
  @spec update_artist_link(Actor.t(), String.t(), Loader.integer_id(), map()) ::
          {:ok, {User.t(), ArtistLink.t()}}
          | {:error, {ArtistLink.t(), Ecto.Changeset.t()}}
          | {:error, Authorization.write_error_reason() | :not_found}
  def update_artist_link(%Actor{} = actor, slug, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, artist_link} <- load_scoped_artist_link(actor, :update, slug, id) do
      case update_artist_link(artist_link, attrs) do
        {:ok, artist_link} -> {:ok, {artist_link.user, artist_link}}
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
  @spec verify_artist_link(Actor.t(), Loader.integer_id()) ::
          {:ok, ArtistLink.t()}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def verify_artist_link(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, artist_link} <- load_artist_link(actor, :verify, id) do
      transact_and_log(
        fn -> verify_loaded_link(artist_link, actor.user) end,
        &transition_log(actor, :verify, &1)
      )
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
  @spec reject_artist_link(Actor.t(), Loader.integer_id()) ::
          {:ok, ArtistLink.t()}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def reject_artist_link(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, artist_link} <- load_artist_link(actor, :reject, id) do
      transact_and_log(
        fn -> reject_loaded_link(artist_link) end,
        &transition_log(actor, :reject, &1)
      )
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
  @spec contact_artist_link(Actor.t(), Loader.integer_id()) ::
          {:ok, ArtistLink.t()}
          | {:error, Authorization.write_error_reason() | :not_found | Ecto.Changeset.t()}
  def contact_artist_link(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, artist_link} <- load_artist_link(actor, :contact, id) do
      transact_and_log(
        fn -> contact_loaded_link(artist_link, actor.user) end,
        &transition_log(actor, :contact, &1)
      )
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
  @spec count_artist_links(User.t() | nil) :: non_neg_integer() | nil
  def count_artist_links(user) do
    if authorize(user, :index, ArtistLink) == :ok do
      ArtistLink
      |> where([ul], ul.aasm_state in ^["unverified", "link_verified"])
      |> Repo.aggregate(:count)
    else
      nil
    end
  end
end
