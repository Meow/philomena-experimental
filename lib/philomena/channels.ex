defmodule Philomena.Channels do
  @moduledoc """
  The Channels context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Loader

  alias Philomena.Attribution.Actor
  alias Philomena.Channels.AutomaticUpdater
  alias Philomena.Channels.Channel
  alias Philomena.IntegerId
  alias Philomena.Notifications
  alias Philomena.Tags

  use Philomena.Subscriptions,
    on_delete: :clear_channel_notification,
    id_name: :channel_id

  @doc """
  Updates all the tracked channels for which an update scheme is known.
  """
  def update_tracked_channels! do
    AutomaticUpdater.update_tracked_channels!()
  end

  # Creates a channel. Visible for testing.
  @doc false
  @spec create_channel(map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def create_channel(attrs \\ %{}) do
    %Channel{}
    |> update_artist_tag(attrs)
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  # Updates a channel.
  @spec update_channel(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  defp update_channel(%Channel{} = channel, attrs) do
    channel
    |> update_artist_tag(attrs)
    |> Channel.changeset(attrs)
    |> Repo.update()
  end

  # Adds the artist tag from the `"artist_tag"` tag name attribute.
  defp update_artist_tag(%Channel{} = channel, attrs) do
    tag =
      attrs
      |> Map.get("artist_tag", "")
      |> Tags.get_tag_by_name()

    Channel.artist_tag_changeset(channel, tag)
  end

  # Deletes a channel.
  @spec delete_channel(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  defp delete_channel(%Channel{} = channel) do
    Repo.delete(channel)
  end

  # Returns an `%Ecto.Changeset{}` for tracking channel changes.
  defp change_channel(%Channel{} = channel) do
    Channel.changeset(channel, %{})
  end

  defp list_channels(show_nsfw?, params, pagination) do
    Channel
    |> maybe_show_nsfw(show_nsfw?)
    |> where([c], not is_nil(c.last_fetched_at))
    |> order_by(desc: :is_live, asc: :title)
    |> join(:left, [c], _ in assoc(c, :associated_artist_tag))
    |> preload([_c, t], associated_artist_tag: t)
    |> maybe_search(params)
    |> Repo.paginate(pagination)
  end

  @doc """
  Loads the livestream listing and the acting user's subscription state.

  Only channels the fetcher has stamped (`last_fetched_at` set) are listed,
  ordered live-first and then by title. `show_nsfw?` includes NSFW channels;
  a non-empty `"cq"` matches title, short name, or artist tag name. Subscription
  state is scoped to the actor's user and is empty for an anonymous actor.

  ## Examples

      iex> load_channels(actor, false, %{"cq" => "pony"}, pagination)
      {%Scrivener.Page{}, %{12 => true}}

  """
  @spec load_channels(Actor.t(), boolean(), map(), Repo.pagination_params()) ::
          {Scrivener.Page.t(), %{optional(integer()) => true}}
  def load_channels(%Actor{} = actor, show_nsfw?, params, pagination) do
    channels = list_channels(show_nsfw?, params, pagination)
    {channels, subscriptions(channels, actor.user)}
  end

  @doc """
  Clears the acting user's live notification for the channel named by the
  `id`, returning the channel and its external stream URL.

  ## Examples

      iex> visit_channel(user, "1")
      {:ok, %Channel{}}

      iex> visit_channel(user, "999999999")
      {:error, :unauthorized}

      iex> visit_channel(admin, "999999999")
      {:error, :not_found}

  """
  @spec visit_channel(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def visit_channel(%Actor{} = actor, id) do
    # TODO: why do we ever return unauthorized?
    with {:ok, channel} <- load_channel(actor, id, :show) do
      clear_channel_notification(channel, actor.user)
      {:ok, channel}
    end
  end

  @doc """
  Clears the acting user's live notification for the channel named by the
  `id`, returning the channel.

  ## Examples

      iex> clear_notification(user, "1")
      {:ok, %Channel{}}

      iex> clear_notification(user, "999999999")
      {:error, :not_found}

  """
  @spec clear_notification(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :not_found}
  def clear_notification(%Actor{} = actor, id) do
    with {:ok, id} <- IntegerId.parse(id),
         %Channel{} = channel <- Repo.get(Channel, id) do
      clear_channel_notification(channel, actor.user)
      {:ok, channel}
    else
      _ -> {:error, :not_found}
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
  @spec new_channel(Actor.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_channel(%Actor{} = actor) do
    with :ok <- authorize(actor, :new, Channel) do
      {:ok, change_channel(%Channel{})}
    end
  end

  @doc """
  Creates a channel on behalf of `actor`.

  Inserts the channel with the artist tag resolved from the `"artist_tag"` attribute.

  ## Examples

      iex> create_channel(moderator, %{"type" => "PicartoChannel", "short_name" => "x"})
      {:ok, %Channel{}}

      iex> create_channel(moderator, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_channel(user, channel_params)
      {:error, :unauthorized}

  """
  @spec create_channel(Actor.t(), map()) ::
          {:ok, Channel.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_channel(%Actor{} = actor, attrs) do
    with :ok <- authorize(actor, :create, Channel) do
      create_channel(attrs)
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
          {:ok, {Channel.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_channel_for_edit(%Actor{} = actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :edit) do
      {:ok, {channel, change_channel(channel)}}
    end
  end

  @doc """
  Updates the channel named by the `id`, on behalf of `actor`.

  On success only the `:type` and `:short_name` fields are applied;
  the fetcher-managed fields are ignored.

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
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def update_channel(%Actor{} = actor, id, attrs) do
    with {:ok, channel} <- load_channel(actor, id, :update) do
      update_channel(channel, attrs)
    end
  end

  @doc """
  Updates a channel's state when it goes live.

  ## Examples

      iex> update_channel_state(channel, %{field: new_value})
      {:ok, %Channel{}}

      iex> update_channel_state(channel, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_channel_state(%Channel{} = channel, attrs) do
    channel
    |> Channel.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes the channel named by the `id`, on behalf of `actor`.

  Loading and authorization follow `update_channel/3`, authorizing `:delete`.

  Returns `{:ok, channel}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> delete_channel(moderator, "1")
      {:ok, %Channel{}}

  """
  @spec delete_channel(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def delete_channel(%Actor{} = actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :delete) do
      delete_channel(channel)
    end
  end

  @doc """
  Removes all channel notifications for a given channel and user.

  ## Examples

      iex> clear_channel_notification(channel, user)
      :ok

  """
  def clear_channel_notification(%Channel{} = channel, user) do
    Notifications.clear_channel_live_notification(channel, user)
    :ok
  end

  @doc """
  Subscribes `actor` to the channel named by the `id`.

  Subscribing is idempotent.

  ## Examples

      iex> subscribe(user, "1")
      {:ok, %Channel{}}

      iex> subscribe(user, "999999999")
      {:error, :unauthorized}

      iex> subscribe(admin, "999999999")
      {:error, :not_found}

  """
  @spec subscribe(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def subscribe(%Actor{} = actor, id) do
    # TODO: why do we ever return unauthorized?
    # TODO: pretty sure it's not possible for the subscription insert to fail
    with {:ok, channel} <- load_channel(actor, id, :show),
         {:ok, _subscription} <- create_subscription(channel, actor.user) do
      {:ok, channel}
    end
  end

  @doc """
  Unsubscribes `actor` from the channel named by the `id`.

  Unsubscribing is idempotent.

  ## Examples

      iex> unsubscribe(user, "1")
      {:ok, %Channel{}}

      iex> unsubscribe(user, "999999999")
      {:error, :unauthorized}

      iex> unsubscribe(admin, "999999999")
      {:error, :not_found}

  """
  @spec unsubscribe(Actor.t(), Loader.integer_id()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def unsubscribe(%Actor{} = actor, id) do
    # TODO: why do we ever return unauthorized?
    with {:ok, channel} <- load_channel(actor, id, :show) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(channel, actor.user)
      {:ok, channel}
    end
  end

  # Loads a channel by id and authorizes `action` against it.
  @spec load_channel(Actor.t(), Loader.integer_id(), atom()) ::
          Loader.fetch_and_authorize_result(Channel.t())
  defp load_channel(actor, id, action) do
    Loader.fetch_and_authorize(Channel, actor, action, id)
  end

  defp maybe_search(query, %{"cq" => cq}) when is_binary(cq) and cq != "" do
    title_query = "#{cq}%"
    tag_query = "%#{cq}%"

    where(
      query,
      [c, t],
      ilike(c.title, ^title_query) or ilike(c.short_name, ^title_query) or
        ilike(t.name, ^tag_query)
    )
  end

  defp maybe_search(query, _params), do: query

  defp maybe_show_nsfw(query, true), do: query
  defp maybe_show_nsfw(query, _falsy), do: where(query, [c], c.nsfw == false)
end
