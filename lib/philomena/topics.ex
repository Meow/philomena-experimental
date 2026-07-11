defmodule Philomena.Topics do
  @moduledoc """
  The Topics context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Topics.Topic
  alias Philomena.Forums
  alias Philomena.Forums.Forum
  alias Philomena.Posts
  alias Philomena.UserStatistics
  alias Philomena.Notifications
  alias Philomena.Users.User

  use Philomena.Subscriptions,
    on_delete: :clear_topic_notification,
    id_name: :topic_id

  @doc """
  Subscribes `actor` (the acting user) to the topic named by `topic_slug`
  within the forum named by `forum_slug`.

  The forum is loaded by its short name and authorized for `:show`; the topic
  is then loaded by its slug within that forum. Because the subscribe path
  never revealed hidden topics, a hidden topic that the actor may not `:show`
  comes back `{:error, :unauthorized}`.

  Returns `{:ok, {forum, topic}}` (both are needed to render the subscription
  partial), `{:error, :unauthorized}` when the forum or topic is not visible to
  the actor, `{:error, :not_found}` when the forum exists but the topic does
  not, or `{:error, %Ecto.Changeset{}}` if the subscription insert is rejected.

  ## Examples

      iex> subscribe(user, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

      iex> subscribe(user, "dis", "nonexistent")
      {:error, :not_found}

  """
  @spec subscribe(User.t() | nil, String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def subscribe(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         {:ok, _subscription} <- create_subscription(topic, actor) do
      {:ok, {forum, topic}}
    end
  end

  @doc """
  Unsubscribes `actor` (the acting user) from the topic named by `topic_slug`
  within the forum named by `forum_slug`.

  Loading mirrors `subscribe/3` except that hidden topics stay visible on this
  path (unsubscribing from a topic that was hidden after subscription must keep
  working), so only the forum `:show` and the topic existence checks can fail.

  Returns `{:ok, {forum, topic}}`, `{:error, :unauthorized}` when the forum is
  not visible to the actor, or `{:error, :not_found}` when the forum exists but
  the topic does not.

  ## Examples

      iex> unsubscribe(user, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unsubscribe(User.t() | nil, String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}} | {:error, :unauthorized | :not_found}
  def unsubscribe(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: true) do
      # Deletion is idempotent and cannot fail; the hard match pins the crash
      # semantics of the plug-based controller this replaces.
      {:ok, _subscription} = delete_subscription(topic, actor)
      {:ok, {forum, topic}}
    end
  end

  # Reproduces the retired plug chain: the forum was loaded by short name and
  # authorized for `:show` (an unknown forum authorizes `nil`, which no
  # ordinary rule permits, so it is unauthorized), then the topic was loaded by
  # slug within that forum. `show_hidden` is the LoadTopicPlug option that
  # diverged the two actions on hidden topics.
  defp load_forum_topic(actor, forum_slug, topic_slug, opts) do
    show_hidden = Keyword.get(opts, :show_hidden, false)
    forum = Repo.get_by(Forum, short_name: to_string(forum_slug))

    with :ok <- authorize(actor, :show, forum),
         {:ok, topic} <- load_topic_in_forum(actor, forum, topic_slug, show_hidden) do
      {:ok, forum, topic}
    end
  end

  defp load_topic_in_forum(actor, forum, topic_slug, show_hidden) do
    Topic
    |> where(forum_id: ^forum.id, slug: ^to_string(topic_slug))
    |> Repo.one()
    |> authorize_topic_visibility(actor, show_hidden)
  end

  defp authorize_topic_visibility(nil, _actor, _show_hidden),
    do: {:error, :not_found}

  defp authorize_topic_visibility(%Topic{hidden_from_users: false} = topic, _actor, _show_hidden),
    do: {:ok, topic}

  # A hidden topic is visible only when the caller opted into hidden topics (the
  # unsubscribe path) or the actor may `:show` it.
  defp authorize_topic_visibility(%Topic{} = topic, _actor, true),
    do: {:ok, topic}

  defp authorize_topic_visibility(%Topic{} = topic, actor, false) do
    with :ok <- authorize(actor, :show, topic) do
      {:ok, topic}
    end
  end

  @doc """
  Gets a single topic.

  Raises `Ecto.NoResultsError` if the Topic does not exist.

  ## Examples

      iex> get_topic!(123)
      %Topic{}

      iex> get_topic!(456)
      ** (Ecto.NoResultsError)

  """
  def get_topic!(id), do: Repo.get!(Topic, id)

  @doc """
  Creates a topic.

  ## Examples

      iex> create_topic(%{field: value})
      {:ok, %Topic{}}

      iex> create_topic(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_topic(forum, attribution, attrs \\ %{}) do
    now = DateTime.utc_now(:second)

    topic =
      %Topic{}
      |> Topic.creation_changeset(attrs, forum, attribution)

    Multi.new()
    |> Multi.insert(:topic, topic)
    |> Multi.run(:update_topic, fn repo, %{topic: topic} ->
      {count, nil} =
        Topic
        |> where(id: ^topic.id)
        |> repo.update_all(set: [last_post_id: hd(topic.posts).id, last_replied_to_at: now])

      {:ok, count}
    end)
    |> Multi.run(:update_forum, fn repo, %{topic: topic} ->
      {count, nil} =
        Forum
        |> where(id: ^topic.forum_id)
        |> repo.update_all(
          inc: [post_count: 1, topic_count: 1],
          set: [last_post_id: hd(topic.posts).id]
        )

      {:ok, count}
    end)
    |> Multi.run(:notification, &notify_topic/2)
    |> maybe_subscribe_on(:topic, attribution[:user], :watch_on_new_topic)
    |> Repo.transaction()
    |> case do
      {:ok, %{topic: topic}} = result ->
        UserStatistics.inc_stat(topic.user_id, :topics_count)
        Posts.reindex_post(hd(topic.posts))
        Posts.report_non_approved(hd(topic.posts))

        result

      error ->
        error
    end
  end

  defp notify_topic(_repo, %{topic: topic}) do
    Notifications.create_forum_topic_notification(topic.user, topic)
  end

  @doc """
  Updates a topic.

  ## Examples

      iex> update_topic(topic, %{field: new_value})
      {:ok, %Topic{}}

      iex> update_topic(topic, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_topic(%Topic{} = topic, attrs) do
    topic
    |> Topic.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Topic.

  ## Examples

      iex> delete_topic(topic)
      {:ok, %Topic{}}

      iex> delete_topic(topic)
      {:error, %Ecto.Changeset{}}

  """
  def delete_topic(%Topic{} = topic) do
    Repo.delete(topic)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking topic changes.

  ## Examples

      iex> change_topic(topic)
      %Ecto.Changeset{source: %Topic{}}

  """
  def change_topic(%Topic{} = topic) do
    Topic.changeset(topic, %{})
  end

  @doc """
  Makes a topic sticky, appearing at the top of its forum.

  ## Examples

      iex> stick_topic(topic)
      {:ok, %Topic{}}

  """
  def stick_topic(topic) do
    Topic.stick_changeset(topic)
    |> Repo.update()
  end

  @doc """
  Removes sticky status from a topic.

  ## Examples

      iex> unstick_topic(topic)
      {:ok, %Topic{}}

  """
  def unstick_topic(topic) do
    Topic.unstick_changeset(topic)
    |> Repo.update()
  end

  @doc """
  Locks a topic to prevent further posting.

  ## Examples

      iex> lock_topic(topic, %{"lock_reason" => "Off topic"}, user)
      {:ok, %Topic{}}

  """
  def lock_topic(%Topic{} = topic, attrs, user) do
    Topic.lock_changeset(topic, attrs, user)
    |> Repo.update()
  end

  @doc """
  Unlocks a topic to allow posting again.

  ## Examples

      iex> unlock_topic(topic)
      {:ok, %Topic{}}

  """
  def unlock_topic(%Topic{} = topic) do
    Topic.unlock_changeset(topic)
    |> Repo.update()
  end

  @doc """
  Moves a topic to a different forum, updating post counts for both forums.

  ## Examples

      iex> move_topic(topic, 123)
      {:ok, %{topic: %Topic{}}}

      iex> move_topic(topic, 456)
      {:error, %Ecto.Changeset{}}

  """
  def move_topic(topic, new_forum_id) do
    old_forum_id = topic.forum_id

    Multi.new()
    |> Multi.update(:topic, Topic.move_changeset(topic, new_forum_id))
    |> Multi.update_all(
      :old_forum,
      Forums.update_forum_last_post_query(old_forum_id),
      inc: [post_count: -topic.post_count, topic_count: -1]
    )
    |> Multi.update_all(
      :new_forum,
      Forums.update_forum_last_post_query(new_forum_id),
      inc: [post_count: topic.post_count, topic_count: 1]
    )
    |> Repo.transaction()
    |> normalize_multi_error()
  end

  @doc """
  Hides a topic and updates related forum data.

  ## Examples

      iex> hide_topic(topic, "Violates rules", moderator)
      {:ok, %Topic{}}

      iex> hide_topic(topic, "", moderator)
      {:error, %Ecto.Changeset{}}

  """
  def hide_topic(topic, deletion_reason, user) do
    topic = topic |> Repo.preload(:user)

    Multi.new()
    |> Multi.update(:topic, Topic.hide_changeset(topic, deletion_reason, user))
    |> Multi.update_all(
      :forum,
      Forums.update_forum_last_post_query(topic.forum_id),
      inc: [post_count: -topic.post_count, topic_count: -1]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{topic: topic}} ->
        UserStatistics.inc_stat(topic.user_id, :topics_count, -1)
        Posts.reindex_posts_in_topic(topic.id)

        {:ok, topic}

      error ->
        normalize_multi_error(error)
    end
  end

  @doc """
  Unhides a previously hidden topic.

  ## Examples

      iex> unhide_topic(topic)
      {:ok, %Topic{}}

  """
  def unhide_topic(topic) do
    topic = topic |> Repo.preload(:user)

    Multi.new()
    |> Multi.update(:topic, Topic.unhide_changeset(topic))
    |> Multi.update_all(
      :forum,
      Forums.update_forum_last_post_query(topic.forum_id),
      inc: [post_count: topic.post_count, topic_count: 1]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{topic: topic}} ->
        UserStatistics.inc_stat(topic.user_id, :topics_count)
        Posts.reindex_posts_in_topic(topic.id)

        {:ok, topic}

      error ->
        error
    end
  end

  @doc """
  Updates a topic's title.

  ## Examples

      iex> update_topic_title(topic, %{"title" => "New Title"})
      {:ok, %Topic{}}

  """
  def update_topic_title(topic, attrs) do
    topic
    |> Topic.title_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Removes all topic notifications for a given topic and user.

  ## Examples

      iex> clear_topic_notification(topic, user)
      :ok

  """
  def clear_topic_notification(%Topic{} = topic, user) do
    Notifications.clear_forum_post_notification(topic, user)
    Notifications.clear_forum_topic_notification(topic, user)
    :ok
  end

  @doc """
  Returns an `m:Ecto.Query` which updates the last post for the given topic.

  ## Examples

      iex> update_topic_last_post_query(1)
      #Ecto.Query<...>

  """
  def update_topic_last_post_query(topic_id) do
    Topic
    |> where(id: ^topic_id)
    |> update(
      set: [
        last_post_id:
          fragment(
            "SELECT max(id) FROM posts WHERE topic_id = ? AND hidden_from_users IS FALSE",
            ^topic_id
          )
      ]
    )
  end

  # `Repo.transaction/1` reports a failed step as `{:error, name, value, changes}`.
  # Callers only ever want the changeset that failed, in the shape every other
  # context function returns it.
  defp normalize_multi_error({:error, _name, %Ecto.Changeset{} = changeset, _changes}),
    do: {:error, changeset}

  defp normalize_multi_error(result), do: result
end
