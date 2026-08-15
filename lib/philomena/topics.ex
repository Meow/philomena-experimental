defmodule Philomena.Topics do
  @moduledoc """
  Topic reads, creation, subscriptions, and moderation.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Multi
  alias Philomena.Repo

  alias Philomena.Topics.{ForumTopic, Topic, TopicPage}
  alias Philomena.Forums
  alias Philomena.Forums.Forum
  alias Philomena.Forums.Visibility
  alias Philomena.Posts
  alias Philomena.Posts.Post
  alias Philomena.Polls
  alias Philomena.Polls.Poll
  alias Philomena.PollVotes
  alias Philomena.PollOptions.PollOption
  alias Philomena.UserStatistics
  alias Philomena.Notifications
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.RateLimiter
  alias Philomena.Attribution.Actor
  alias Philomena.Users.User

  @topic_create_window 300

  use Philomena.Subscriptions,
    on_delete: :clear_topic_notification,
    id_name: :topic_id

  defp persist_topic(%Forum{} = forum, %Actor{} = actor, attrs) do
    now = DateTime.utc_now(:second)

    topic =
      %Topic{}
      |> Topic.creation_changeset(attrs, forum, actor)

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
    |> maybe_subscribe_on(:topic, actor.user, :watch_on_new_topic)
    |> Multi.transact()
    |> case do
      {:ok, %{topic: topic}} = result ->
        UserStatistics.increment(topic.user_id, :topics_count)
        Posts.reindex_post(hd(topic.posts))
        Posts.report_non_approved(hd(topic.posts))

        result

      error ->
        error
    end
  end

  defp notify_topic(_repo, %{topic: topic}) do
    Notifications.broadcast_forum_topic(topic.user, topic)
  end

  defp broadcast_topic_creation(%{forum: %{access_level: "normal"}} = result) do
    PhilomenaWeb.Endpoint.broadcast!(
      "firehose",
      "post:create",
      PhilomenaWeb.Api.Json.Forum.Topic.PostView.render("firehose.json", result)
    )

    result
  end

  defp broadcast_topic_creation(result), do: result

  defp persist_topic_stick(%Topic{} = topic) do
    topic
    |> Topic.stick_changeset()
    |> Repo.update()
  end

  # Removes sticky status from a topic.
  defp unstick_topic(%Topic{} = topic) do
    topic
    |> Topic.unstick_changeset()
    |> Repo.update()
  end

  defp persist_topic_lock(%Topic{} = topic, attrs, %User{} = user) do
    topic
    |> Topic.lock_changeset(attrs, user)
    |> Repo.update()
  end

  # Unlocks a topic to allow posting again.
  defp unlock_topic(%Topic{} = topic) do
    topic
    |> Topic.unlock_changeset()
    |> Repo.update()
  end

  # Moves a topic to a different forum, updating post counts for both forums.
  defp move_topic(%Topic{} = topic, new_forum_id) do
    old_forum_id = topic.forum_id

    # TODO: need to lock the forum
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
    |> Multi.transact()
    |> normalize_multi_error()
  end

  defp hide_loaded_topic(%Topic{} = topic, deletion_reason, %User{} = user) do
    topic = topic |> Repo.preload(:user)

    # TODO: need to lock the forum
    Multi.new()
    |> Multi.update(:topic, Topic.hide_changeset(topic, deletion_reason, user))
    |> Multi.update_all(
      :forum,
      Forums.update_forum_last_post_query(topic.forum_id),
      inc: [post_count: -topic.post_count, topic_count: -1]
    )
    |> Multi.transact()
    |> case do
      {:ok, %{topic: topic}} ->
        UserStatistics.increment(topic.user_id, :topics_count, -1)
        Posts.reindex_posts_in_topic(topic)

        {:ok, topic}

      error ->
        normalize_multi_error(error)
    end
  end

  defp unhide_loaded_topic(%Topic{} = topic) do
    topic = topic |> Repo.preload(:user)

    Multi.new()
    |> Multi.update(:topic, Topic.unhide_changeset(topic))
    |> Multi.update_all(
      :forum,
      Forums.update_forum_last_post_query(topic.forum_id),
      inc: [post_count: topic.post_count, topic_count: 1]
    )
    |> Multi.transact()
    |> case do
      {:ok, %{topic: topic}} ->
        UserStatistics.increment(topic.user_id, :topics_count)
        Posts.reindex_posts_in_topic(topic)

        {:ok, topic}

      error ->
        error
    end
  end

  # Updates a topic's title.
  defp update_topic_title(%Topic{} = topic, attrs) do
    topic
    |> Topic.title_changeset(attrs)
    |> Repo.update()
  end

  # Returns an `%Ecto.Changeset{}` for tracking topic changes.
  defp change_topic(%Topic{} = topic) do
    Topic.changeset(topic, %{})
  end

  defp load_topic_in_forum(%Actor{} = actor, action, forum, topic_slug, preloads)
       when is_binary(topic_slug) do
    Topic
    |> where(forum_id: ^forum.id, slug: ^topic_slug)
    |> preload(^preloads)
    |> Loader.one_and_authorize(actor, action)
  end

  defp load_topic_in_forum(_actor, _action, _forum, _topic_slug, _preloads),
    do: {:error, :not_found}

  defp topic_pagination(%Topic{} = topic, post_id_param, pagination) do
    page_number =
      with {:ok, post_id} <- IntegerId.parse(post_id_param),
           [post] <- Post |> where(id: ^post_id, topic_id: ^topic.id) |> Repo.all() do
        div(post.topic_position, pagination.page_size) + 1
      else
        _ -> pagination.page_number
      end

    %{pagination | page_number: page_number}
  end

  defp load_topic_posts(%Topic{} = topic, %{page_number: page_number, page_size: page_size}) do
    entries =
      Post
      |> where(topic_id: ^topic.id)
      |> where([p], p.topic_position >= ^(page_size * (page_number - 1)))
      |> where([p], p.topic_position < ^(page_size * page_number))
      |> order_by(asc: :created_at, asc: :id)
      |> preload([:deleted_by, :topic, topic: :forum, user: [awards: :badge]])
      |> Repo.all()

    %Scrivener.Page{
      entries: entries,
      page_number: page_number,
      page_size: page_size,
      total_entries: topic.post_count,
      total_pages: div(topic.post_count + page_size - 1, page_size)
    }
  end

  defp load_target_forum(%Actor{} = actor, topic_params) do
    target_id = if is_map(topic_params), do: Map.get(topic_params, "target_forum_id")
    Loader.fetch_and_authorize(Forum, actor, :show, target_id)
  end

  defp normalize_multi_error({:error, _name, %Ecto.Changeset{} = changeset, _changes}),
    do: {:error, changeset}

  defp normalize_multi_error(result), do: result

  @doc """
  Paginates homepage topics visible to `actor`.

  Forum access uses the shared forum hierarchy scopes. Topics with titles
  containing `"NSFW"` are omitted. Forums and last post users are preloaded.

  ## Examples

      iex> list_front_page_topics(actor, 6)
      [%Topic{}, ...]

  """
  @spec list_front_page_topics(Actor.t(), Repo.pagination_params()) :: Scrivener.Page.t(Topic.t())
  def list_front_page_topics(%Actor{} = actor, pagination) do
    visible_forums = Visibility.visible_forums(Forum, actor)

    Topic
    |> join(:inner, [topic], forum in subquery(visible_forums), on: forum.id == topic.forum_id)
    |> Visibility.visible_topics(actor)
    |> where([topic], fragment("? !~ ?", topic.title, "NSFW"))
    |> order_by(desc: :last_replied_to_at)
    |> preload([:forum, last_post: :user])
    |> Repo.paginate(pagination)
  end

  @doc """
  Subscribes `actor` to the topic named by `topic_slug` within the forum
  named by `forum_slug`.

  Write access is verified first. The forum is then authorized for `:show`, and
  the topic is queried beneath it and authorized for `:subscribe`.

  Returns `{:ok, {forum, topic}}` (both are returned for the caller to reuse),
  `{:error, :unauthorized}` when the forum or topic is not visible to
  the actor, `{:error, :not_found}` when the forum exists but the topic does
  not, or `{:error, %Ecto.Changeset{}}` if the subscription insert is rejected.

  ## Examples

      iex> subscribe(user, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

      iex> subscribe(user, "dis", "nonexistent")
      {:error, :not_found}

  """
  @spec subscribe(actor :: Actor.t(), forum_slug :: String.t(), topic_slug :: String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def subscribe(%Actor{} = actor, forum_slug, topic_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :subscribe),
         {:ok, _subscription} <- create_subscription(topic, actor.user) do
      {:ok, {forum, topic}}
    end
  end

  @doc """
  Unsubscribes `actor` from the topic named by `topic_slug` within the forum
  named by `forum_slug`.

  Write access is verified first. Loading mirrors `subscribe/3`, but the topic
  uses the separate `:unsubscribe` action so a user may stop watching a topic
  that became hidden after subscription.

  Returns `{:ok, {forum, topic}}`, `{:error, :unauthorized}` when the forum is
  not visible to the actor, or `{:error, :not_found}` when the forum exists but
  the topic does not.

  ## Examples

      iex> unsubscribe(user, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unsubscribe(actor :: Actor.t(), forum_slug :: String.t(), topic_slug :: String.t()) ::
          {:ok, {Forum.t(), Topic.t()}} | {:error, :ban | :unauthorized | :not_found}
  def unsubscribe(%Actor{} = actor, forum_slug, topic_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :unsubscribe) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(topic, actor.user)
      {:ok, {forum, topic}}
    end
  end

  @doc """
  Loads the forum named by `forum_slug` and, within it, the topic named by
  `topic_slug`, on behalf of `actor`.

  The forum is loaded by short name and authorized for `:show`, then the topic
  is queried by slug and `forum.id` before authorization. Callers may select an
  action and preloads with `:action` and `:preloads`; the default action is
  `:show`. Malformed or missing route members are not-found, while a loaded
  member forbidden for that action is unauthorized.

  This is the loader that `Philomena.Polls` reuses so poll editing shares the
  exact forum/topic visibility semantics used when loading topics.

  ## Examples

      iex> load_forum_topic(moderator_actor, "dis", "some-topic", action: :show)
      {:ok, %ForumTopic{}}

  """
  @spec load_forum_topic(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          opts :: keyword()
        ) ::
          {:ok, ForumTopic.t()} | {:error, :unauthorized | :not_found}
  def load_forum_topic(%Actor{} = actor, forum_slug, topic_slug, opts \\ []) do
    action = Keyword.get(opts, :action, :show)
    preloads = Keyword.get(opts, :preloads, [])

    with {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_topic_in_forum(actor, action, forum, topic_slug, preloads) do
      {:ok, %ForumTopic{forum: forum, topic: topic}}
    end
  end

  @doc """
  Clears `actor`'s unread notifications for the topic named by `topic_slug`
  within the forum named by `forum_slug`.

  The forum is authorized for `:show`, then the topic is queried beneath it and
  authorized for `:mark_read`. That action deliberately permits a subscribed
  user to clear notifications after the topic itself becomes hidden.

  Returns `{:ok, topic}` after clearing the notifications, not-found for a
  missing route member, or unauthorized for a forbidden forum/topic.

  ## Examples

      iex> mark_topic_read(actor, "dis", "some-topic")
      {:ok, %Topic{}}

      iex> mark_topic_read(actor, "dis", "nonexistent")
      {:error, :not_found}

  """
  @spec mark_topic_read(Actor.t(), String.t(), String.t()) ::
          {:ok, Topic.t()} | {:error, :not_found | :unauthorized}
  def mark_topic_read(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, %ForumTopic{topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :mark_read) do
      clear_topic_notification(topic, actor.user)
      {:ok, topic}
    end
  end

  @doc """
  Assembles the `TopicPage` for the topic named by `topic_slug` within the
  forum named by `forum_slug`, on behalf of `actor`.

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them.
  As a side effect, `actor`'s unread notifications for the topic are cleared.

  `post_id_param` is the `post_id` to jump to (or `nil`): when it
  parses to an integer naming an existing post, the returned page is the one
  containing that post (by its position over the page size), but only when the
  post belongs to the loaded topic. Otherwise `pagination` is used as-is.

  The `posts` field is a `Scrivener.Page` of raw `Post` structs, ordered by
  creation, with the topic, forum, and author preloaded); their Markdown bodies
  are left raw for the caller.

  Returns `{:ok, %TopicPage{}}`, `{:error, :unauthorized}` when the forum or the
  topic is not visible to `actor`, or `{:error, :not_found}` when the forum
  exists but the topic does not.

  ## Examples

      iex> load_topic_page(user, "dis", "some-topic", nil, %{page_number: 1})
      {:ok, %TopicPage{}}

  """
  @spec load_topic_page(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          post_id_param :: String.t() | nil,
          pagination :: Repo.pagination_params()
        ) ::
          {:ok, TopicPage.t()} | {:error, :unauthorized | :not_found}
  def load_topic_page(%Actor{} = actor, forum_slug, topic_slug, post_id_param, pagination) do
    with {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug) do
      topic = Repo.preload(topic, [:user, :forum, :deleted_by, :locked_by, poll: :options])
      pagination = topic_pagination(topic, post_id_param, pagination)

      clear_topic_notification(topic, actor.user)

      {:ok,
       %TopicPage{
         forum: forum,
         topic: topic,
         posts: load_topic_posts(topic, pagination),
         watching: subscribed?(topic, actor.user),
         voted: PollVotes.voted?(actor, topic.poll),
         poll_active: Polls.active?(topic.poll),
         post_changeset: Posts.change_post(%Post{}),
         topic_changeset: change_topic(topic)
       }}
    end
  end

  @doc """
  Loads a visible topic beneath its route forum, with its author preloaded.

  ## Examples

      iex> load_topic(actor, "dis", "some-topic")
      {:ok, %ForumTopic{}}

      iex> load_topic(actor, "dis", "nonexistent")
      {:error, :not_found}

  """
  @spec load_topic(Actor.t(), String.t(), String.t()) ::
          {:ok, ForumTopic.t()} | {:error, :not_found | :unauthorized}
  def load_topic(%Actor{} = actor, forum_slug, topic_slug) do
    load_forum_topic(actor, forum_slug, topic_slug, preloads: [:user])
  end

  @doc """
  Creates a topic, on behalf of `actor`.

  `actor`'s write access is verified first. The forum is then loaded by short
  name and authorized for `:show`, and the topic together with its first post
  is inserted from `topic_params`. On success, the returned map carries the
  topic, forum, and first post.

  Returns `{:ok, %{topic: topic, forum: forum, post: post}}` on success,
  `{:error, forum, changeset}` when the topic changeset is rejected,
  `{:error, :creation_failed, forum}` when the insert fails for another reason,
  or `{:error, :ban | :unauthorized}` from the write-access and forum checks.
  A non-exempt actor who has created a topic within the last 5 minutes gets
  `{:error, :rate_limited}`.

  ## Examples

      iex> create_topic(actor, "dis", %{"title" => "Hi", "posts" => %{"0" => %{"body" => "Yo"}}})
      {:ok, %{topic: %Topic{}, forum: %Forum{}, post: %Post{}}}

  """
  @spec create_topic(Actor.t(), String.t(), map() | nil) ::
          {:ok, %{topic: Topic.t(), forum: Forum.t(), post: Post.t()}}
          | {:error, Forum.t(), Ecto.Changeset.t()}
          | {:error, :creation_failed, Forum.t()}
          | {:error, :ban | :unauthorized | :rate_limited}
  @spec create_topic(Forum.t(), keyword(), map()) ::
          {:ok, %{topic: Topic.t()}} | {:error, atom(), Ecto.Changeset.t(), map()}
  def create_topic(%Actor{} = actor, forum_slug, topic_params) do
    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :topic_create),
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         :ok <- authorize(actor, :create_topic, forum) do
      case persist_topic(forum, actor, topic_params || %{}) do
        {:ok, %{topic: topic}} ->
          RateLimiter.record_action(actor, :topic_create, @topic_create_window)
          result = %{topic: topic, forum: forum, post: hd(topic.posts)}

          {:ok, broadcast_topic_creation(result)}

        {:error, :topic, changeset, _changes} ->
          {:error, forum, changeset}

        _error ->
          {:error, :creation_failed, forum}
      end
    end
  end

  @doc """
  Returns a new-topic changeset for `actor` in the forum named by `forum_slug`.

  Write access is verified first; the forum is then loaded by short name
  and authorized for `:create_topic`. The returned changeset is
  seeded with an empty first post and a two-option poll so those nested fields
  are present.

  Returns `{:ok, {forum, changeset}}` (the forum is returned for the caller to
  reuse), `{:error, :ban}` for a banned actor, or `{:error, :unauthorized}` when
  the forum is not visible to `actor`.

  ## Examples

      iex> load_new_topic(actor, "dis")
      {:ok, {%Forum{}, %Ecto.Changeset{}}}

  """
  @spec load_new_topic(Actor.t(), String.t()) ::
          {:ok, {Forum.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :not_found | :unauthorized}
  def load_new_topic(%Actor{} = actor, forum_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         :ok <- authorize(actor, :create_topic, forum) do
      changeset =
        change_topic(%Topic{
          poll: %Poll{options: [%PollOption{}, %PollOption{}]},
          posts: [%Post{}]
        })

      {:ok, {forum, changeset}}
    end
  end

  @doc """
  Sticks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor`.

  Write access is verified first, then the topic is authorized for `:stick`
   On success a moderation log is written attributing the change.

  Returns `{:ok, {forum, topic}}` on success (both are returned for the caller
  to reuse), `{:error, forum, topic}` when the stick changeset is rejected,
  `{:error, :unauthorized}` when the actor may not see the forum/topic or
  stick the topic, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> stick_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec stick_topic(actor :: Actor.t(), forum_slug :: String.t(), topic_slug :: String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def stick_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :stick) do
      case persist_topic_stick(topic) do
        {:ok, topic} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Stick:create",
            Paths.topic_path(forum, topic),
            "Stickied topic '#{topic.title}' in #{forum.name}"
          )

          {:ok, {forum, topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Unsticks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor`.

  Loading and authorization mirror `stick_topic/3`, using the distinct
  `:unstick` action. On success a moderation log is written.

  Returns `{:ok, {forum, topic}}` on success, `{:error, forum, topic}` if the
  unstick is rejected (so the caller can act on it), `{:error, :unauthorized}`,
  or `{:error, :not_found}`.

  ## Examples

      iex> unstick_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unstick_topic(actor :: Actor.t(), forum_slug :: String.t(), topic_slug :: String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def unstick_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :unstick) do
      case unstick_topic(topic) do
        {:ok, topic} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Stick:delete",
            Paths.topic_path(forum, topic),
            "Unstickied topic '#{topic.title}' in #{forum.name}"
          )

          {:ok, {forum, topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Locks the topic named by `topic_slug` within the forum named by `forum_slug`,
  recording the lock reason from `topic_params`, on behalf of `actor` (the
  acting user).

  Write access is verified first, then the parent-scoped topic is authorized
  for `:lock`. On success a moderation log is written attributing the change.

  Returns `{:ok, {forum, topic}}` on success (both are returned for the caller
  to reuse), `{:error, forum, topic}` when the lock changeset is rejected
  (e.g. a blank reason, so the caller can still act on it),
  `{:error, :unauthorized}` when the actor may not see the forum/topic
  or lock the topic, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> lock_topic(moderator, "dis", "some-topic", %{"lock_reason" => "Off topic"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> lock_topic(moderator, "dis", "some-topic", %{"lock_reason" => ""})
      {:error, %Forum{}, %Topic{}}

  """
  @spec lock_topic(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          topic_params :: map()
        ) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def lock_topic(%Actor{} = actor, forum_slug, topic_slug, topic_params) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :lock) do
      case persist_topic_lock(topic, topic_params, actor.user) do
        {:ok, topic} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Lock:create",
            Paths.topic_path(forum, topic),
            "Locked topic '#{topic.title}' (#{topic.lock_reason}) in #{forum.name}"
          )

          {:ok, {forum, topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Unlocks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor`.

  Loading and authorization mirror `lock_topic/4`, using the distinct
  `:unlock` action. On success a moderation log is written.

  Returns `{:ok, {forum, topic}}` on success, `{:error, forum, topic}` if the
  unlock is rejected (so the caller can act on it),
  `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unlock_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unlock_topic(actor :: Actor.t(), forum_slug :: String.t(), topic_slug :: String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def unlock_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :unlock) do
      case unlock_topic(topic) do
        {:ok, topic} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Lock:delete",
            Paths.topic_path(forum, topic),
            "Unlocked topic '#{topic.title}' in #{forum.name}"
          )

          {:ok, {forum, topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Moves the topic named by `topic_slug` within the forum named by `forum_slug`
  to the forum identified by the `"target_forum_id"` key of `topic_params`, on
  behalf of `actor`.

  Write access is verified first and the parent-scoped topic is authorized for
  `:move`. On success the target forum is preloaded (needed for the log body
  and for the caller to reuse), post/topic counts are updated for both forums, and
  a moderation log is written.

  Returns `{:ok, {new_forum, topic}}` on success (the target forum is returned
  for the caller to reuse), `{:error, forum, topic}` carrying the source forum and
  topic when the move cannot happen, `{:error, :unauthorized}` when the actor may
  not see the forum/topic or move the topic, or `{:error, :not_found}` when the
  topic does not exist.

  ## Examples

      iex> move_topic(moderator, "dis", "some-topic", %{"target_forum_id" => "3"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> move_topic(moderator, "dis", "some-topic", %{"target_forum_id" => "bogus"})
      {:error, %Forum{}, %Topic{}}

  """
  @spec move_topic(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          topic_params :: map() | nil
        ) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def move_topic(%Actor{} = actor, forum_slug, topic_slug, topic_params) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :move) do
      with {:ok, target_forum} <- load_target_forum(actor, topic_params),
           {:ok, %{topic: moved_topic}} <- move_topic(topic, target_forum.id) do
        ModerationLogs.create_moderation_log(
          actor,
          "Topic.Move:create",
          Paths.topic_path(target_forum, moved_topic),
          "Topic '#{moved_topic.title}' moved to #{target_forum.name}"
        )

        {:ok, {target_forum, moved_topic}}
      else
        _ -> {:error, forum, topic}
      end
    end
  end

  @doc """
  Hides the topic named by `topic_slug` within the forum named by `forum_slug`,
  recording `deletion_reason`, on behalf of `actor`.

  Write access is verified first, then the parent-scoped topic is authorized
  for `:hide`. On success the forum post/topic counts are updated, the topic's
  posts are reindexed, and a moderation log is written attributing the deletion
  to the actor.

  Returns `{:ok, {forum, topic}}` on success, `{:error, forum, topic}` when the hide
  changeset is rejected (e.g. a blank reason, so the caller can still act on it),
  `{:error, :unauthorized}` when the actor may not see the forum/topic or hide the
  topic, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> hide_topic(moderator, "dis", "some-topic", "Rule violation")
      {:ok, {%Forum{}, %Topic{}}}

      iex> hide_topic(moderator, "dis", "some-topic", "")
      {:error, %Forum{}, %Topic{}}

  """
  @spec hide_topic(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          deletion_reason :: String.t() | nil
        ) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def hide_topic(%Actor{} = actor, forum_slug, topic_slug, deletion_reason) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :hide) do
      case hide_loaded_topic(topic, deletion_reason, actor.user) do
        {:ok, topic} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Hide:create",
            Paths.topic_path(forum, topic),
            "Deleted topic '#{topic.title}' (#{topic.deletion_reason}) in #{forum.name}"
          )

          {:ok, {forum, topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Restores the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor`.

  Loading and authorization mirror `hide_topic/4` (`:show` on the forum,
  visibility on the topic, then `:hide` on the topic - a moderator can still
  see the hidden topic here). On success the forum counts are restored, the
  topic's posts are reindexed, and a moderation log is written.

  Returns `{:ok, {forum, topic}}` on success, `{:error, forum, topic}` if the
  restore is rejected (so the caller can act on it),
  `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unhide_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unhide_topic(actor :: Actor.t(), forum_slug :: String.t(), topic_slug :: String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def unhide_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :unhide) do
      case unhide_loaded_topic(topic) do
        {:ok, topic} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Hide:delete",
            Paths.topic_path(forum, topic),
            "Restored topic '#{topic.title}' in #{forum.name}"
          )

          {:ok, {forum, topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Updates the title of the topic named by `topic_slug` within the forum named by
  `forum_slug` from `topic_params`, on behalf of `actor`.

  The forum is loaded by short name and authorized for `:show`, the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them,
  and the `:edit` permission on the topic is then checked. Only the title is
  updated; the slug is left intact.

  Returns `{:ok, {forum, topic}}` on success (both are returned for the caller to
  reuse), `{:error, forum, topic}` when the title changeset is rejected (carrying
  the forum and pre-update topic for the caller to reuse),
  `{:error, :unauthorized}` when the forum or topic is not visible or may not be
  edited, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> update_topic_title(moderator, "dis", "some-topic", %{"title" => "New Title"})
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec update_topic_title(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          topic_params :: map()
        ) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def update_topic_title(%Actor{} = actor, forum_slug, topic_slug, topic_params) do
    with :ok <- verify_write_access(actor),
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           load_forum_topic(actor, forum_slug, topic_slug, action: :update_title) do
      case update_topic_title(topic, topic_params) do
        {:ok, updated_topic} ->
          {:ok, {forum, updated_topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Hides one loaded topic for permanent user erasure.

  This collaboration service owns the counter, indexing, and visibility
  side effects required by `Philomena.Users.Eraser`. It is not a request
  authorization boundary; the erasure workflow has already selected the topic
  and staff user.

  ## Examples

      iex> erase_topic(topic, moderator)
      {:ok, %Topic{hidden_from_users: true}}

  """
  @spec erase_topic(Topic.t(), User.t()) ::
          {:ok, Topic.t()} | {:error, term()}
  def erase_topic(%Topic{} = topic, %User{} = moderator) do
    hide_loaded_topic(topic, "Site abuse", moderator)
  end

  @doc """
  Removes all topic notifications for a given topic and user.

  ## Examples

      iex> clear_topic_notification(topic, user)
      :ok

  """
  @spec clear_topic_notification(Topic.t(), User.t() | nil) :: :ok
  def clear_topic_notification(%Topic{} = topic, user) do
    Notifications.clear_forum_post(topic, user)
    Notifications.clear_forum_topic(topic, user)
    :ok
  end

  @doc """
  Returns an `m:Ecto.Query` which updates the last post for the given topic.

  ## Examples

      iex> update_topic_last_post_query(1)
      #Ecto.Query<...>

  """
  @spec update_topic_last_post_query(integer()) :: Ecto.Query.t()
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
end
