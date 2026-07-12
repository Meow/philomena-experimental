defmodule Philomena.Channels do
  @moduledoc """
  The Channels context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Channels.AutomaticUpdater
  alias Philomena.Channels.Channel
  alias Philomena.IntegerId
  alias Philomena.Notifications
  alias Philomena.Tags
  alias Philomena.Users.User

  use Philomena.Subscriptions,
    on_delete: :clear_channel_notification,
    id_name: :channel_id

  @doc """
  Updates all the tracked channels for which an update scheme is known.
  """
  def update_tracked_channels! do
    AutomaticUpdater.update_tracked_channels!()
  end

  @doc """
  Gets a single channel.

  Raises `Ecto.NoResultsError` if the Channel does not exist.

  ## Examples

      iex> get_channel!(123)
      %Channel{}

      iex> get_channel!(456)
      ** (Ecto.NoResultsError)

  """
  def get_channel!(id), do: Repo.get!(Channel, id)

  @doc """
  Returns a page of channels for the livestreams index.

  Only channels the fetcher has stamped (`last_fetched_at` set) are listed,
  ordered live-first and then by title, with the associated artist tag
  preloaded. `show_nsfw?` includes NSFW channels when true. A non-empty
  `"cq"` in `params` matches the channel title, short name, or artist tag
  name.

  ## Examples

      iex> list_channels(false, %{"cq" => "pony"}, pagination)
      %Scrivener.Page{}

  """
  @spec list_channels(boolean(), map(), map()) :: Scrivener.Page.t()
  def list_channels(show_nsfw?, params, pagination) do
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
  Clears the acting user's live notification for the channel named by the raw
  request `id`, returning the channel so the caller can redirect to its
  external stream URL.

  The channel is loaded by id and authorized for `:show`; every user may view a
  channel, so a visible channel always succeeds. A non-castable id is
  `{:error, :not_found}`. An unknown id authorizes `nil`: no ordinary rule
  permits it, so a non-admin gets `{:error, :unauthorized}` while an admin gets
  `{:error, :not_found}`.

  ## Examples

      iex> visit_channel(user, "1")
      {:ok, %Channel{}}

      iex> visit_channel(user, "999999999")
      {:error, :unauthorized}

  """
  @spec visit_channel(User.t() | nil, any()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def visit_channel(actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :show) do
      clear_channel_notification(channel, actor)
      {:ok, channel}
    end
  end

  @doc """
  Clears the acting user's live notification for the channel named by the raw
  request `id`, returning the channel.

  No authorization is performed - any signed-in user may mark a channel's live
  notification read. A non-castable or unknown id is `{:error, :not_found}`.

  ## Examples

      iex> clear_notification(user, "1")
      {:ok, %Channel{}}

      iex> clear_notification(user, "999999999")
      {:error, :not_found}

  """
  @spec clear_notification(User.t() | nil, any()) ::
          {:ok, Channel.t()} | {:error, :not_found}
  def clear_notification(actor, id) do
    with {:ok, id} <- IntegerId.parse(id),
         %Channel{} = channel <- Repo.get(Channel, id) do
      clear_channel_notification(channel, actor)
      {:ok, channel}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Builds the changeset backing the new-channel form, on behalf of `actor`.

  Authorizes `:new` against the channel model. Returns
  `{:ok, %Ecto.Changeset{}}` or `{:error, :unauthorized}`.

  ## Examples

      iex> new_channel(moderator)
      {:ok, %Ecto.Changeset{}}

      iex> new_channel(user)
      {:error, :unauthorized}

  """
  @spec new_channel(User.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_channel(%User{} = actor) do
    with :ok <- authorize(actor, :new, Channel) do
      {:ok, change_channel(%Channel{})}
    end
  end

  @doc """
  Creates a channel on behalf of `actor`.

  Authorizes `:create` against the channel model, then inserts the channel with
  the artist tag resolved from the `"artist_tag"` attribute.

  Returns `{:ok, channel}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}` if the insert is rejected.

  ## Examples

      iex> create_channel(moderator, %{"type" => "PicartoChannel", "short_name" => "x"})
      {:ok, %Channel{}}

  """
  @spec create_channel(User.t(), map()) ::
          {:ok, Channel.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_channel(%User{} = actor, attrs) do
    with :ok <- authorize(actor, :create, Channel) do
      create_channel(attrs)
    end
  end

  @doc """
  Creates a channel.

  This is the authorization-free engine used by `create_channel/2` and by
  fetcher tooling.

  ## Examples

      iex> create_channel(%{field: value})
      {:ok, %Channel{}}

      iex> create_channel(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_channel(map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def create_channel(attrs \\ %{}) do
    %Channel{}
    |> update_artist_tag(attrs)
    |> Channel.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Loads the channel named by the raw request `id` for editing, on behalf of
  `actor`, pairing it with the changeset backing the edit form.

  Loading and authorization follow `update_channel/3`, authorizing `:edit`.

  ## Examples

      iex> load_channel_for_edit(moderator, "1")
      {:ok, {%Channel{}, %Ecto.Changeset{}}}

  """
  @spec load_channel_for_edit(User.t(), any()) ::
          {:ok, {Channel.t(), Ecto.Changeset.t()}} | {:error, :not_found | :unauthorized}
  def load_channel_for_edit(%User{} = actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :edit) do
      {:ok, {channel, change_channel(channel)}}
    end
  end

  @doc """
  Updates the channel named by the raw request `id`, on behalf of `actor`.

  The channel is loaded and `:update` is authorized: a non-castable id is
  `{:error, :not_found}`, an unknown id authorizes `nil` and comes back
  `{:error, :unauthorized}` for a non-admin (admins get `{:error, :not_found}`),
  and an actor without edit rights on a real channel gets
  `{:error, :unauthorized}`. On success only the `:type` and `:short_name`
  fields are applied; the fetcher-managed fields are ignored.

  Returns `{:ok, channel}`, `{:error, :not_found}`, `{:error, :unauthorized}`,
  or `{:error, %Ecto.Changeset{}}`.

  ## Examples

      iex> update_channel(moderator, "1", %{"short_name" => "renamed"})
      {:ok, %Channel{}}

  """
  @spec update_channel(User.t(), any(), map()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def update_channel(%User{} = actor, id, attrs) do
    with {:ok, channel} <- load_channel(actor, id, :update) do
      update_channel(channel, attrs)
    end
  end

  @doc """
  Updates a channel.

  ## Examples

      iex> update_channel(channel, %{field: new_value})
      {:ok, %Channel{}}

      iex> update_channel(channel, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_channel(Channel.t(), map()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def update_channel(%Channel{} = channel, attrs) do
    channel
    |> update_artist_tag(attrs)
    |> Channel.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Adds the artist tag from the `"artist_tag"` tag name attribute.

  ## Examples

      iex> update_artist_tag(%Channel{}, %{"artist_tag" => "artist:nighty"})
      %Ecto.Changeset{}

  """
  def update_artist_tag(%Channel{} = channel, attrs) do
    tag =
      attrs
      |> Map.get("artist_tag", "")
      |> Tags.get_tag_by_name()

    Channel.artist_tag_changeset(channel, tag)
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
  Deletes the channel named by the raw request `id`, on behalf of `actor`.

  Loading and authorization follow `update_channel/3`, authorizing `:delete`.

  Returns `{:ok, channel}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> delete_channel(moderator, "1")
      {:ok, %Channel{}}

  """
  @spec delete_channel(User.t(), any()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def delete_channel(%User{} = actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :delete) do
      delete_channel(channel)
    end
  end

  @doc """
  Deletes a Channel.

  ## Examples

      iex> delete_channel(channel)
      {:ok, %Channel{}}

      iex> delete_channel(channel)
      {:error, %Ecto.Changeset{}}

  """
  @spec delete_channel(Channel.t()) :: {:ok, Channel.t()} | {:error, Ecto.Changeset.t()}
  def delete_channel(%Channel{} = channel) do
    Repo.delete(channel)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking channel changes.

  ## Examples

      iex> change_channel(channel)
      %Ecto.Changeset{source: %Channel{}}

  """
  def change_channel(%Channel{} = channel) do
    Channel.changeset(channel, %{})
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
  Subscribes `actor` to the channel named by the raw request `id`.

  The channel is loaded by id and authorized for `:show`. A non-castable id is
  `{:error, :not_found}`. A well-formed but unknown id is authorized as a `nil`
  load: a non-admin gets `{:error, :unauthorized}` and an admin
  `{:error, :not_found}`. Subscribing is idempotent.

  Returns `{:ok, channel}` (the channel is needed to render the subscription
  partial), or `{:error, %Ecto.Changeset{}}` if the subscription insert is
  rejected.

  ## Examples

      iex> subscribe(user, "1")
      {:ok, %Channel{}}

      iex> subscribe(user, "999999999")
      {:error, :unauthorized}

  """
  @spec subscribe(User.t() | nil, any()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized | Ecto.Changeset.t()}
  def subscribe(actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :show),
         {:ok, _subscription} <- create_subscription(channel, actor) do
      {:ok, channel}
    end
  end

  @doc """
  Unsubscribes `actor` from the channel named by the raw request `id`.

  Loading and authorization mirror `subscribe/2`. Unsubscribing is idempotent
  and cannot fail.

  Returns `{:ok, channel}`, `{:error, :not_found}`, or
  `{:error, :unauthorized}`.

  ## Examples

      iex> unsubscribe(user, "1")
      {:ok, %Channel{}}

  """
  @spec unsubscribe(User.t() | nil, any()) ::
          {:ok, Channel.t()} | {:error, :not_found | :unauthorized}
  def unsubscribe(actor, id) do
    with {:ok, channel} <- load_channel(actor, id, :show) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(channel, actor)
      {:ok, channel}
    end
  end

  # Loads a channel by raw request id and authorizes `action` against it. A
  # non-castable id is not found; an unknown id authorizes the `nil` load, which
  # only an admin may act on, and the nil then reports not found.
  defp load_channel(actor, id, action) do
    with {:ok, id} <- IntegerId.parse(id),
         channel = Repo.get(Channel, id),
         :ok <- authorize(actor, action, channel),
         %Channel{} <- channel do
      {:ok, channel}
    else
      shape when shape in [:error, nil] -> {:error, :not_found}
      {:error, :unauthorized} -> {:error, :unauthorized}
    end
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
