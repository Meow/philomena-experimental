defmodule Philomena.Channels do
  @moduledoc """
  Livestream discovery, staff-managed channel configuration, and per-user
  subscription/read state.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.Channels.AutomaticUpdater
  alias Philomena.Channels.Channel
  alias Philomena.Channels.QueryBuilder
  alias Philomena.Channels.QueryForm
  alias Philomena.Loader
  alias Philomena.Notifications
  alias Philomena.Repo
  alias Philomena.Tags

  use Philomena.Subscriptions,
    id_name: :channel_id

  defp change_channel(%Channel{} = channel, attrs) do
    changeset = Channel.changeset(channel, attrs)

    case Channel.artist_tag_name(changeset) do
      {:ok, nil = artist_tag_name} ->
        Channel.artist_tag_changeset(changeset, artist_tag_name, nil)

      {:ok, artist_tag_name} ->
        tag = Tags.find_canonical_tag_by_name(artist_tag_name)
        Channel.artist_tag_changeset(changeset, artist_tag_name, tag)

      _error ->
        changeset
    end
  end

  defp clear_notification_for(%Channel{} = channel, user) do
    Notifications.clear_channel_live(channel, user)
    :ok
  end

  defp load_channel(actor, id, action) do
    Loader.fetch_and_authorize(Channel, actor, action, id)
  end

  defp maybe_show_nsfw(query, true), do: query
  defp maybe_show_nsfw(query, _falsy), do: where(query, nsfw: false)

  @doc """
  Updates all tracked channels for which an automatic fetch scheme is known.

  Raises when the updater cannot maintain its fetch invariant.

  ## Examples

      iex> update_tracked_channels!()
      :ok

  """
  @spec update_tracked_channels!() :: :ok
  def update_tracked_channels! do
    AutomaticUpdater.update_tracked_channels!()
  end

  @doc """
  Loads the livestream listing and the acting user's subscription state.

  Only channels the fetcher has stamped (`last_fetched_at` set) are listed,
  ordered live-first and then by title. `show_nsfw?` includes NSFW channels;
  a non-empty `"cq"` matches title, short name, or artist tag name. Subscription
  state is scoped to the actor's user and is empty for an anonymous actor.

  ## Examples

      iex> load_channels(actor, false, %{"cq" => "pony"}, pagination)
      {:ok, %Scrivener.Page{}, %{12 => true}, %Ecto.Changeset{}}

  """
  @spec load_channels(Actor.t(), boolean(), map(), Repo.pagination_params()) ::
          {:ok, Scrivener.Page.t(), %{optional(integer()) => true}, Ecto.Changeset.t()}
          | {:error, Ecto.Changeset.t()}
  def load_channels(%Actor{} = actor, show_nsfw?, params, pagination) do
    with {:ok, query, query_form} <- QueryBuilder.build_query(params) do
      channels =
        query
        |> maybe_show_nsfw(show_nsfw?)
        |> where([c], not is_nil(c.last_fetched_at))
        |> order_by(desc: :is_live, asc: :title)
        |> preload([:associated_artist_tag])
        |> Repo.paginate(pagination)

      {:ok, channels, subscriptions(channels, actor.user), QueryForm.changeset(query_form)}
    end
  end

  @doc """
  Loads the channel named by `id` for a public visit and clears the acting
  user's live notification when signed in.

  The named `:visit` ability permits anonymous browsing. Malformed and missing
  IDs are always `{:error, :not_found}`.

  ## Examples

      iex> visit_channel(user, "1")
      {:ok, %Channel{}}

      iex> visit_channel(actor, "999999999")
      {:error, :not_found}

  """
  @spec visit_channel(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def visit_channel(%Actor{} = actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :visit) do
      clear_notification_for(channel, actor.user)
      {:ok, channel}
    end
  end

  @doc """
  Clears the acting user's live notification for the channel named by the
  `id`, returning the channel.

  This authenticated read-state operation authorizes `:mark_read`. It is
  specifically exempt from `verify_write_access`.

  ## Examples

      iex> clear_notification(user, "1")
      {:ok, %Channel{}}

      iex> clear_notification(user, "999999999")
      {:error, :not_found}

  """
  @spec clear_notification(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def clear_notification(%Actor{} = actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :mark_read) do
      clear_notification_for(channel, actor.user)
      {:ok, channel}
    end
  end

  @doc """
  Builds the changeset for a new channel, on behalf of `actor`.

  ## Examples

      iex> new_channel(moderator)
      {:ok, %Ecto.Changeset{}}

      iex> new_channel(user)
      {:error, :unauthorized}

  """
  @spec new_channel(Actor.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized}
  def new_channel(%Actor{} = actor) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, Channel) do
      {:ok, Channel.changeset(%Channel{})}
    end
  end

  @doc """
  Creates a channel on behalf of `actor`.

  An optional artist tag can be specified in the `"artist_tag"` attribute.

  ## Examples

      iex> create_channel(moderator, %{"type" => "PicartoChannel", "short_name" => "x"})
      {:ok, %Channel{}}

      iex> create_channel(moderator, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_channel(user, channel_params)
      {:error, :unauthorized}

  """
  @spec create_channel(Actor.t(), map()) ::
          {:ok, Channel.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def create_channel(%Actor{} = actor, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Channel) do
      %Channel{}
      |> change_channel(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Loads the channel named by the `id` for editing, on behalf of
  `actor`, pairing it with a change-tracking changeset.

  ## Examples

      iex> load_channel_for_edit(moderator, "1")
      {:ok, {%Channel{}, %Ecto.Changeset{}}}

      iex> load_channel_for_edit(moderator, "999999999")
      {:error, :not_found}

      iex> load_channel_for_edit(user, "1")
      {:error, :unauthorized}

  """
  @spec load_channel_for_edit(Actor.t(), Loader.integer_id()) ::
          {:ok, {Channel.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def load_channel_for_edit(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, channel} <- load_channel(actor, id, :edit) do
      {:ok, {channel, Channel.changeset(channel)}}
    end
  end

  @doc """
  Updates the channel named by the `id`, on behalf of `actor`.

  On success, only `:type` and `:short_name` are applied.
  Fetcher-managed fields are ignored.

  ## Examples

      iex> update_channel(moderator, "1", %{"short_name" => "renamed"})
      {:ok, %Channel{}}

      iex> update_channel(moderator, "1", invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_channel(moderator, "999999999", channel_params)
      {:error, :not_found}

      iex> update_channel(user, "1", channel_params)
      {:error, :unauthorized}

  """
  @spec update_channel(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Channel.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def update_channel(%Actor{} = actor, id, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, channel} <- load_channel(actor, id, :update) do
      channel
      |> change_channel(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Updates channel state from the automatic updater.

  This function is not request-facing and performs no authorization.

  ## Examples

      iex> update_fetch_state(channel, %{field: new_value})
      {:ok, %Channel{}}

      iex> update_fetch_state(channel, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_fetch_state(Channel.t(), map()) ::
          {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def update_fetch_state(%Channel{} = channel, attrs) do
    channel
    |> Channel.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes the channel named by the `id`, on behalf of `actor`.

  ## Examples

      iex> delete_channel(moderator, "1")
      {:ok, %Channel{}}

  """
  @spec delete_channel(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :ban | :not_found | :unauthorized}
  def delete_channel(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, channel} <- load_channel(actor, id, :delete) do
      Repo.delete(channel)
    end
  end

  @doc """
  Subscribes `actor` to the channel named by the `id`.

  Repeated subscription is an idempotent success. Unexpected persistence
  failures are returned as changeset errors.

  ## Examples

      iex> subscribe(user, "1")
      {:ok, %Channel{}}

      iex> subscribe(anonymous_actor, "1")
      {:error, :unauthorized}

      iex> subscribe(user, "999999999")
      {:error, :not_found}

  """
  @spec subscribe(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()}
          | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def subscribe(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, channel} <- load_channel(actor, id, :subscribe),
         {:ok, _subscription} <- create_subscription(channel, actor.user) do
      {:ok, channel}
    end
  end

  @doc """
  Unsubscribes `actor` from the channel named by the `id`.

  Repeated unsubscription is an idempotent success and also clears any live
  notification for the channel.

  ## Examples

      iex> unsubscribe(user, "1")
      {:ok, %Channel{}}

      iex> unsubscribe(anonymous_actor, "1")
      {:error, :unauthorized}

      iex> unsubscribe(user, "999999999")
      {:error, :not_found}

  """
  @spec unsubscribe(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :ban | :not_found | :unauthorized}
  def unsubscribe(%Actor{} = actor, id) do
    with :ok <- verify_write_access(actor),
         {:ok, channel} <- load_channel(actor, id, :unsubscribe),
         {:ok, _subscription} <- delete_subscription(channel, actor.user) do
      clear_notification_for(channel, actor.user)
      {:ok, channel}
    end
  end
end
