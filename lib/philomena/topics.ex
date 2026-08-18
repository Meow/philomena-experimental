defmodule Philomena.Topics do
  @moduledoc """
  Topic reads, creation, subscriptions, and moderation.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  import Philomena.Forums.TransactionWorkflow

  alias Philomena.Multi
  alias Philomena.Repo

  alias Philomena.Topics.{MoveForm, Topic, TopicPage}
  alias Philomena.Forums
  alias Philomena.Forums.Forum
  alias Philomena.Forums.Visibility
  alias Philomena.Posts
  alias Philomena.Posts.Post
  alias Philomena.Polls
  alias Philomena.Polls.Poll
  alias Philomena.PollVotes
  alias Philomena.PollOptions.PollOption
  alias Philomena.Notifications
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.Loader
  alias Philomena.RateLimiter
  alias Philomena.Attribution.Actor
  alias Philomena.Users.User
  alias Philomena.UserStatistics

  @topic_create_window 300

  use Philomena.Subscriptions,
    on_delete: :clear_topic_notification,
    id_name: :topic_id

  defp broadcast_topic_creation(%{forum: %{access_level: "normal"}} = result) do
    PhilomenaWeb.Endpoint.broadcast!(
      "firehose",
      "post:create",
      PhilomenaWeb.Api.Json.Forum.Topic.PostView.render("firehose.json", result)
    )

    result
  end

  defp broadcast_topic_creation(result), do: result

  defp notify_topic(_repo, %{topic: topic}) do
    Notifications.broadcast_forum_topic(topic.user, topic)
  end

  defp topic_pagination(%Actor{} = actor, %Topic{} = topic, post_id, pagination) do
    page_number =
      Post
      |> where(topic_id: ^topic.id)
      |> Loader.fetch_and_authorize(actor, :show, post_id)
      |> case do
        {:ok, post} ->
          div(post.topic_position, pagination.page_size) + 1

        _ ->
          pagination.page_number
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

  defp hide_topic_steps(user, forum_slug, topic_slug, params) do
    Multi.new()
    |> put_forum_and_topic_locks(user, forum_slug, :show, topic_slug, :hide)
    |> Multi.update(:topic, fn %{locked_topic: topic} ->
      Topic.hide_changeset(topic, user, params)
    end)
    |> put_topic_visibility_counters(visible?: false)
    |> put_refresh_topic_last_post()
    |> put_refresh_forum_last_post()
    |> Posts.put_reindex_posts_in_topic()
  end

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
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :subscribe),
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
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :unsubscribe) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(topic, actor.user)
      {:ok, {forum, topic}}
    end
  end

  @doc """
  Loads the the topic named by `topic_slug` within `forum`, for `action`,
  on behalf of `actor`.

  The topic is queried by slug and `forum.id` before authorization. Malformed or
  missing route members are not-found, while a loaded member forbidden for that
  action is unauthorized.

  ## Examples

      iex> load_forum_topic(moderator_actor, forum, "some-topic", :show)
      {:ok, %Topic{}}

  """
  def load_forum_topic(%Actor{} = actor, %Forum{} = forum, topic_slug, action) do
    Topic
    |> where(forum_id: ^forum.id, slug: ^topic_slug)
    |> preload([:user, :forum])
    |> Loader.one_and_authorize(actor, action)
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
    with {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :mark_read) do
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
          post_id :: String.t() | nil,
          pagination :: Repo.pagination_params()
        ) ::
          {:ok, TopicPage.t()} | {:error, :unauthorized | :not_found}
  def load_topic_page(%Actor{} = actor, forum_slug, topic_slug, post_id, pagination) do
    with {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :show) do
      topic = Repo.preload(topic, [:user, :forum, :deleted_by, :locked_by, poll: :options])
      pagination = topic_pagination(actor, topic, post_id, pagination)

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
         topic_changeset: Topic.changeset(topic)
       }}
    end
  end

  @doc """
  Loads a visible topic beneath its route forum, with its author preloaded.

  ## Examples

      iex> load_topic(actor, "dis", "some-topic")
      {:ok, %Topic{}}

      iex> load_topic(actor, "dis", "nonexistent")
      {:error, :not_found}

  """
  @spec load_topic(Actor.t(), String.t(), String.t()) ::
          {:ok, Topic.t()} | {:error, :not_found | :unauthorized}
  def load_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum} <- Forums.load_forum(actor, forum_slug) do
      load_forum_topic(actor, forum, topic_slug, :show)
    end
  end

  @doc """
  Creates a topic, on behalf of `actor`.

  `actor`'s write access and the topic-creation rate limit are verified first.
  The forum is then locked, loaded by short name, and authorized for
  `:create_topic` before the topic and its first post are inserted from
  `params`. The topic's last post and the forum's visible counters are updated
  in the same transaction. On success, the returned map carries the topic,
  forum, and first post; the topic is also indexed, reported if unapproved,
  and broadcast when the forum is public.

  Returns `{:ok, %{topic: topic, forum: forum, post: post}}` on success,
  `{:error, forum, changeset}` when the topic changeset is rejected, or
  `{:error, :ban | :unauthorized | :not_found}` from the access, rate-limit,
  forum, or transaction checks. A non-exempt actor who has created a topic
  within the last 5 minutes gets`{:error, :rate_limited}`.

  ## Examples

      iex> create_topic(actor, "dis", %{"title" => "Hi", "posts" => %{"0" => %{"body" => "Yo"}}})
      {:ok, %{topic: %Topic{}, forum: %Forum{}, post: %Post{}}}

  """
  @spec create_topic(Actor.t(), String.t(), map() | nil) ::
          {:ok, %{topic: Topic.t(), forum: Forum.t(), post: Post.t()}}
          | {:error, Forum.t(), Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized | :rate_limited}
  @spec create_topic(Forum.t(), keyword(), map()) ::
          {:ok, %{topic: Topic.t()}} | {:error, atom(), Ecto.Changeset.t(), map()}
  def create_topic(%Actor{user: creator} = actor, forum_slug, params) do
    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :topic_create) do
      Multi.new()
      |> put_forum_lock(actor, forum_slug, :create_topic)
      |> Multi.insert(:topic, fn %{locked_forum: forum} ->
        Topic.creation_changeset(%Topic{}, params, forum, actor)
      end)
      |> put_topic_visibility_counters(visible?: true)
      |> UserStatistics.put_increment(creator, :posts_count)
      |> put_refresh_topic_last_post(:topic)
      |> put_refresh_forum_last_post()
      |> maybe_subscribe_on(:topic, creator, :watch_on_new_topic)
      |> Multi.run(:notification, &notify_topic/2)
      |> Posts.put_approval_report(fn %{topic: %{posts: [post]}} -> post end)
      |> Posts.put_reindex_posts_in_topic()
      |> Multi.transact()
      |> case do
        {:ok, %{locked_forum: forum, topic: topic}} ->
          RateLimiter.record_action(actor, :topic_create, @topic_create_window)

          result = %{topic: topic, forum: forum, post: hd(topic.posts)}

          {:ok, broadcast_topic_creation(result)}

        {:error, :topic, changeset, %{locked_forum: forum}} ->
          {:error, forum, changeset}

        error ->
          map_lock_errors(error)
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
        Topic.changeset(%Topic{
          poll: %Poll{options: [%PollOption{}, %PollOption{}]},
          posts: [%Post{}]
        })

      {:ok, {forum, changeset}}
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

      iex> hide_topic(moderator, "dis", "some-topic", %{"deletion_reason" => "Rule violation"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> hide_topic(moderator, "dis", "some-topic", %{})
      {:error, %Forum{}, %Topic{}}

  """
  @spec hide_topic(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          params :: map()
        ) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def hide_topic(%Actor{user: user} = actor, forum_slug, topic_slug, params) do
    with :ok <- verify_write_access(actor) do
      user
      |> hide_topic_steps(forum_slug, topic_slug, params)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        fn %{locked_forum: forum, topic: topic} ->
          {
            "Topic.Hide:create",
            Paths.topic_path(forum, topic),
            "Deleted topic '#{topic.title}' (#{topic.deletion_reason}) in #{forum.name}"
          }
        end
      )
      |> Multi.transact()
      |> case do
        {:ok, %{locked_forum: forum, topic: topic}} ->
          {:ok, {forum, topic}}

        {:error, :topic, _changeset, %{locked_forum: forum, locked_topic: topic}} ->
          {:error, forum, topic}

        error ->
          map_lock_errors(error)
      end
    end
  end

  @doc """
  Restores the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor`.

  The forum and topic are locked together; the forum is authorized for `:show`
  and the topic for `:unhide`, allowing a moderator to see the hidden topic.
  On success the forum counts are restored, the topic's posts are reindexed,
  and a moderation log is written.

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
    with :ok <- verify_write_access(actor) do
      Multi.new()
      |> put_forum_and_topic_locks(actor, forum_slug, :show, topic_slug, :unhide)
      |> Multi.update(:topic, fn %{locked_topic: topic} -> Topic.unhide_changeset(topic) end)
      |> put_topic_visibility_counters(visible?: true)
      |> put_refresh_topic_last_post()
      |> put_refresh_forum_last_post()
      |> Posts.put_reindex_posts_in_topic()
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        fn %{locked_forum: forum, topic: topic} ->
          {
            "Topic.Hide:delete",
            Paths.topic_path(forum, topic),
            "Restored topic '#{topic.title}' in #{forum.name}"
          }
        end
      )
      |> Multi.transact()
      |> case do
        {:ok, %{locked_forum: forum, topic: topic}} ->
          {:ok, {forum, topic}}

        {:error, :topic, _changeset, %{locked_forum: forum, locked_topic: topic}} ->
          {:error, forum, topic}

        error ->
          map_lock_errors(error)
      end
    end
  end

  @doc """
  Moves the topic named by `topic_slug` within the source forum named by
  `source_forum_slug` to the forum identified by the `target_forum` key of
  `params`, on behalf of `actor`.

  Write access is verified first. The source and target forums are locked in a
  consistent order, both are authorized for `:show`, and the topic is
  authorized for `:move`. On success the target forum is returned for the
  caller to reuse, post/topic counts are updated for both forums, and a
  moderation log is written.

  Returns `{:ok, {new_forum, topic}}` on success (the target forum is returned
  for the caller to reuse), `{:error, forum, topic}` carrying the source forum and
  topic when the move cannot happen, `{:error, :unauthorized}` when the actor may
  not see the forum/topic or move the topic, or `{:error, :not_found}` when the
  topic does not exist.

  ## Examples

      iex> move_topic(moderator, "dis", "some-topic", %{"target_forum" => "generals"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> move_topic(moderator, "dis", "some-topic", %{"target_forum" => "bogus"})
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
  def move_topic(%Actor{} = actor, source_forum_slug, topic_slug, params) do
    with :ok <- verify_write_access(actor),
         {:ok, target_forum_slug} <- MoveForm.fetch_target_forum_short_name(params) do
      Multi.new()
      |> put_source_and_target_forum_and_topic_locks(
        actor,
        source_forum_slug,
        :show,
        target_forum_slug,
        :show,
        topic_slug,
        :move
      )
      |> Multi.update(:topic, fn %{locked_topic: topic, locked_target_forum: target_forum} ->
        Topic.move_changeset(topic, target_forum.id)
      end)
      |> put_topic_transfer_counters()
      |> put_refresh_forum_last_post(:locked_source_forum)
      |> put_refresh_forum_last_post(:locked_target_forum)
      |> Posts.put_reindex_posts_in_topic()
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        fn %{locked_target_forum: target_forum, topic: topic} ->
          {
            "Topic.Move:create",
            Paths.topic_path(target_forum, topic),
            "Topic '#{topic.title}' moved to #{target_forum.name}"
          }
        end
      )
      |> Multi.transact()
      |> case do
        {:ok, %{locked_target_forum: target_forum, topic: topic}} ->
          {:ok, {target_forum, topic}}

        {:error, :topic, _changeset, %{locked_source_forum: source_forum, locked_topic: topic}} ->
          {:error, source_forum, topic}

        error ->
          map_lock_errors(error)
      end
    end
  end

  @doc """
  Sticks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor`.

  Write access is verified first, the forum is authorized for `:show`, and the
  topic is authorized for `:stick`. On success a moderation log is written
  attributing the change.

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
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :stick) do
      topic_changeset = Topic.stick_changeset(topic)

      Multi.new()
      |> Multi.update(:topic, topic_changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Topic.Stick:create",
        Paths.topic_path(topic),
        "Stickied topic '#{topic.title}' in #{forum.name}"
      )
      |> Multi.transact()
      |> case do
        {:ok, %{topic: topic}} ->
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
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :unstick) do
      topic_changeset = Topic.unstick_changeset(topic)

      Multi.new()
      |> Multi.update(:topic, topic_changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Topic.Stick:delete",
        Paths.topic_path(topic),
        "Unstickied topic '#{topic.title}' in #{forum.name}"
      )
      |> Multi.transact()
      |> case do
        {:ok, %{topic: topic}} ->
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
  def lock_topic(%Actor{user: user} = actor, forum_slug, topic_slug, params) do
    with :ok <- verify_write_access(actor),
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :lock) do
      topic_changeset = Topic.lock_changeset(topic, params, user)

      Multi.new()
      |> Multi.update(:topic, topic_changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        fn %{topic: topic} ->
          {
            "Topic.Lock:create",
            Paths.topic_path(topic),
            "Locked topic '#{topic.title}' (#{topic.lock_reason}) in #{forum.name}"
          }
        end
      )
      |> Multi.transact()
      |> case do
        {:ok, %{topic: topic}} ->
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
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :unlock) do
      topic_changeset = Topic.unlock_changeset(topic)

      Multi.new()
      |> Multi.update(:topic, topic_changeset)
      |> ModerationLogs.put_log(
        :moderation_log,
        actor,
        "Topic.Lock:delete",
        Paths.topic_path(topic),
        "Unlocked topic '#{topic.title}' in #{forum.name}"
      )
      |> Multi.transact()
      |> case do
        {:ok, %{topic: topic}} ->
          {:ok, {forum, topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Updates the title of the topic named by `topic_slug` within the forum named by
  `forum_slug` from `params`, on behalf of `actor`.

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded beneath it and authorized using the `:update_title` action. Only the title
  is updated; the slug is left intact.

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
          params :: map()
        ) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def update_topic_title(%Actor{} = actor, forum_slug, topic_slug, params) do
    with :ok <- verify_write_access(actor),
         {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- load_forum_topic(actor, forum, topic_slug, :update_title) do
      topic
      |> Topic.title_changeset(params)
      |> Repo.update()
      |> case do
        {:ok, topic} ->
          {:ok, {forum, topic}}

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
          {:ok, Topic.t()} | {:error, Ecto.Changeset.t()} | {:error, :unauthorized | :not_found}
  def erase_topic(%Topic{} = topic, %User{} = moderator) do
    moderator
    |> hide_topic_steps(topic.forum.short_name, topic.slug, %{deletion_reason: "Site abuse"})
    |> Multi.transact()
    |> case do
      {:ok, %{topic: topic}} ->
        {:ok, topic}

      {:error, :topic, %{errors: [hidden_from_users: {"is already hidden", []}]}, _changes} ->
        # Skips all of the above if the topic was already hidden.
        # This is the only expected error.
        {:ok, topic}

      error ->
        map_lock_errors(error)
    end
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
end
