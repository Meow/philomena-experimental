defmodule Philomena.Topics do
  @moduledoc """
  The Topics context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_not_banned: 1, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Topics.Topic
  alias Philomena.Topics.TopicPage
  alias Philomena.Forums
  alias Philomena.Forums.Forum
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
  alias Philomena.RateLimiter
  alias Philomena.Attribution.Actor
  alias Philomena.Users.User

  @topic_create_window 300

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
  @spec subscribe(Actor.t(), String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def subscribe(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         {:ok, _subscription} <- create_subscription(topic, actor.user) do
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
  @spec unsubscribe(Actor.t(), String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}} | {:error, :unauthorized | :not_found}
  def unsubscribe(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: true) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(topic, actor.user)
      {:ok, {forum, topic}}
    end
  end

  @doc """
  Loads the forum named by `forum_slug` and, within it, the topic named by
  `topic_slug`, on behalf of `actor` (the acting user).

  The forum is loaded by short name and authorized for `:show` (an unknown forum
  authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}`), then the topic is loaded by slug within that forum.
  `show_hidden` diverges callers on hidden topics: with `show_hidden: false` (the
  default) a hidden topic is visible only when the actor may `:show` it, otherwise
  `{:error, :unauthorized}`; with `show_hidden: true` a hidden topic always comes
  back.

  Returns `{:ok, forum, topic}`, `{:error, :unauthorized}` when the forum or the
  topic is not visible to the actor, or `{:error, :not_found}` when the forum
  exists but the topic does not.

  This is the loader that `Philomena.Polls` reuses so poll editing shares the
  exact forum/topic visibility semantics used when loading topics.

  ## Examples

      iex> load_forum_topic(moderator, "dis", "some-topic", show_hidden: false)
      {:ok, %Forum{}, %Topic{}}

  """
  @spec load_forum_topic(User.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, Forum.t(), Topic.t()} | {:error, :unauthorized | :not_found}
  def load_forum_topic(actor, forum_slug, topic_slug, opts) do
    show_hidden = Keyword.get(opts, :show_hidden, false)

    with {:ok, forum} <- load_authorized_forum(actor, forum_slug),
         {:ok, topic} <- load_topic_in_forum(actor, forum, topic_slug, show_hidden) do
      {:ok, forum, topic}
    end
  end

  # Loads the forum by short name and authorizes it for `:show`. An unknown short
  # name authorizes `nil`, which no ordinary rule permits, so it comes back
  # `{:error, :unauthorized}` rather than not-found.
  defp load_authorized_forum(actor, forum_slug) do
    forum = Repo.get_by(Forum, short_name: to_string(forum_slug))

    with :ok <- authorize(actor, :show, forum) do
      {:ok, forum}
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
  Clears `actor`'s unread notifications for the topic named by `topic_slug`
  within the forum named by `forum_slug`.

  Unlike the subscription API, this loads with no authorization: the forum is
  loaded by short name, so an unknown short name is `{:error, :not_found}`, and
  the topic is loaded including hidden topics with no `:show` check. There is
  deliberately no forum or topic visibility authorization here - a user can mark
  topics read in a forum they cannot see, and hidden topics can be marked read.

  Returns `{:ok, topic}` after clearing the notifications, or
  `{:error, :not_found}` when the forum or the topic does not exist.

  ## Examples

      iex> mark_topic_read(actor, "dis", "some-topic")
      {:ok, %Topic{}}

      iex> mark_topic_read(actor, "dis", "nonexistent")
      {:error, :not_found}

  """
  @spec mark_topic_read(Actor.t(), String.t(), String.t()) ::
          {:ok, Topic.t()} | {:error, :not_found}
  def mark_topic_read(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, topic} <- load_forum_topic_for_read(actor.user, forum_slug, topic_slug) do
      clear_topic_notification(topic, actor.user)
      {:ok, topic}
    end
  end

  # The read path loaded the forum with a plain `required: true` load, so a
  # missing forum runs the not-found handler rather than authorizing `nil`. The
  # topic is loaded with `show_hidden: true` and no visibility authorization.
  defp load_forum_topic_for_read(actor, forum_slug, topic_slug) do
    case Repo.get_by(Forum, short_name: to_string(forum_slug)) do
      nil ->
        {:error, :not_found}

      forum ->
        load_topic_in_forum(actor, forum, topic_slug, true)
    end
  end

  @doc """
  Assembles the `TopicPage` for the topic named by `topic_slug` within the
  forum named by `forum_slug`, on behalf of `actor` (a
  `Philomena.Attribution.Actor` whose user may be `nil` for an anonymous
  visitor).

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them.
  As a side effect `actor`'s unread notifications for the topic are cleared, so a
  caller maintaining a notification count must refresh it after this returns.

  `post_id_param` is the `post_id` to jump to (or `nil`): when it
  parses to an integer naming an existing post, the returned page is the one
  containing that post (by its position over the fixed page size of 25);
  otherwise `pagination`'s `:page_number` is used. The named post is looked up by
  id alone, not scoped to this topic. `pagination` is the pagination map;
  only its `:page_number` is read.

  The `posts` field is a `Scrivener.Page` of raw `Post` structs (25 per page,
  ordered by creation, with the topic, forum, and author preloaded); their
  Markdown bodies are left raw for the caller.

  Returns `{:ok, %TopicPage{}}`, `{:error, :unauthorized}` when the forum or the
  topic is not visible to `actor`, or `{:error, :not_found}` when the forum
  exists but the topic does not.

  ## Examples

      iex> load_topic_page(user, "dis", "some-topic", nil, %{page_number: 1})
      {:ok, %TopicPage{}}

  """
  @spec load_topic_page(
          Actor.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          Repo.pagination_params()
        ) ::
          {:ok, TopicPage.t()} | {:error, :unauthorized | :not_found}
  def load_topic_page(%Actor{} = actor, forum_slug, topic_slug, post_id_param, pagination) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false) do
      topic = Repo.preload(topic, [:user, :forum, :deleted_by, :locked_by, poll: :options])

      clear_topic_notification(topic, actor.user)

      page = topic_page_number(post_id_param, pagination)

      {:ok,
       %TopicPage{
         forum: forum,
         topic: topic,
         posts: load_topic_posts(topic, page),
         watching: subscribed?(topic, actor.user),
         voted: PollVotes.voted?(topic.poll, actor.user),
         poll_active: Polls.active?(topic.poll),
         post_changeset: Posts.change_post(%Post{}),
         topic_changeset: change_topic(topic)
       }}
    end
  end

  # The requested page is the one holding the post named by `post_id_param` when
  # that parses to an integer naming an existing post; otherwise the page number
  # carried by `pagination`.
  defp topic_page_number(post_id_param, pagination) do
    with {post_id, _extra} <- Integer.parse(post_id_param || ""),
         [post] <- Post |> where(id: ^post_id) |> Repo.all() do
      div(post.topic_position, 25) + 1
    else
      _ -> pagination.page_number
    end
  end

  # One 25-post window of the topic, ordered by creation, with the topic, forum,
  # and author preloaded. The total is taken from the topic's cached post
  # count rather than a separate query.
  defp load_topic_posts(topic, page) do
    entries =
      Post
      |> where(topic_id: ^topic.id)
      |> where([p], p.topic_position >= ^(25 * (page - 1)) and p.topic_position < ^(25 * page))
      |> order_by(asc: :created_at)
      |> preload([:deleted_by, :topic, topic: :forum, user: [awards: :badge]])
      |> Repo.all()

    %Scrivener.Page{
      entries: entries,
      page_number: page,
      page_size: 25,
      total_entries: topic.post_count,
      total_pages: div(topic.post_count + 25 - 1, 25)
    }
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
  Lists the publicly visible topics of the forum named by `forum_short_name`,
  paginated with `pagination`.

  Only topics that are not hidden from users, and that belong to a forum whose
  access level is `"normal"`, are returned - for every requester alike, so
  restricted forums are never exposed here. An unknown or restricted forum
  therefore yields an empty page rather than an error. Results are ordered with
  sticky topics first, then by most recent reply, and their authors are
  preloaded.

  Returns a `Scrivener.Page` of topics.

  ## Examples

      iex> list_public_topics("dis", pagination)
      %Scrivener.Page{}

  """
  @spec list_public_topics(String.t(), map()) :: Scrivener.Page.t()
  def list_public_topics(forum_short_name, pagination) do
    Topic
    |> join(:inner, [t], _ in assoc(t, :forum))
    |> where(hidden_from_users: false)
    |> where([_t, f], f.access_level == "normal" and f.short_name == ^forum_short_name)
    |> order_by(desc: :sticky, desc: :last_replied_to_at)
    |> preload([:user])
    |> Repo.paginate(pagination)
  end

  @doc """
  Fetches a single publicly visible topic by its `slug` within the forum named
  by `forum_short_name`.

  Only a topic that is not hidden from users, and that belongs to a forum whose
  access level is `"normal"`, is returned - for every requester alike. A hidden
  topic, a topic in a restricted forum, a slug under the wrong forum, and an
  unknown slug are all reported as missing. The author is preloaded.

  Returns `{:ok, topic}` or `{:error, :not_found}`.

  ## Examples

      iex> load_public_topic("dis", "some-topic")
      {:ok, %Topic{}}

      iex> load_public_topic("dis", "nonexistent")
      {:error, :not_found}

  """
  @spec load_public_topic(String.t(), String.t()) :: {:ok, Topic.t()} | {:error, :not_found}
  def load_public_topic(forum_short_name, slug) do
    Topic
    |> join(:inner, [t], _ in assoc(t, :forum))
    |> where(slug: ^slug)
    |> where(hidden_from_users: false)
    |> where([_t, f], f.access_level == "normal" and f.short_name == ^forum_short_name)
    |> order_by(desc: :sticky, desc: :last_replied_to_at)
    |> preload([:user])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      topic -> {:ok, topic}
    end
  end

  @doc """
  Creates a topic.

  Called with a `Philomena.Attribution.Actor`, the forum's short name, and
  `topic_params` (which may be `nil`), this is the
  actor-facing entry point. `actor`'s write access is verified first: a
  banned actor is `{:error, :ban}` and an actor with no fingerprint is
  `{:error, :unauthorized}`, neither having touched the forum. The forum is then
  loaded by short name and authorized for `:show`, and the topic together with
  its first post is inserted from `topic_params`, attributed to `actor`'s IP,
  fingerprint, and user. On success the returned map carries the topic, forum,
  and first post the caller needs for the firehose broadcast and to reuse.

  Called with a `%Forum{}`, an attribution keyword list, and topic attributes,
  this is the insertion engine: it performs no authorization and inserts the
  topic, its first post, and the forum/topic bookkeeping in one transaction.

  Returns, for the actor form, `{:ok, %{topic: topic, forum: forum, post: post}}`
  on success, `{:error, forum, changeset}` when the topic changeset is rejected,
  `{:error, :creation_failed, forum}` when the insert fails for another reason,
  or `{:error, :ban |
  :unauthorized}` from the write-access and forum checks. A non-exempt actor who
  has created a topic within the last 5 minutes gets `{:error, :rate_limited}`.
  The engine form returns `{:ok, %{topic: %Topic{}}}` on success or a failed-step
  tuple.

  ## Examples

      iex> create_topic(actor, "dis", %{"title" => "Hi", "posts" => %{"0" => %{"body" => "Yo"}}})
      {:ok, %{topic: %Topic{}, forum: %Forum{}, post: %Post{}}}

      iex> create_topic(forum, attribution, %{field: value})
      {:ok, %{topic: %Topic{}}}

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
         {:ok, forum} <- load_authorized_forum(actor.user, forum_slug) do
      case create_topic(forum, actor_attributes(actor), topic_params || %{}) do
        {:ok, %{topic: topic}} ->
          RateLimiter.record_action(actor, :topic_create, @topic_create_window)
          {:ok, %{topic: topic, forum: forum, post: hd(topic.posts)}}

        {:error, :topic, changeset, _changes} ->
          {:error, forum, changeset}

        _error ->
          {:error, :creation_failed, forum}
      end
    end
  end

  def create_topic(forum, attribution, attrs) do
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

  # The attribution keyword list the insertion engine records, rebuilt from the
  # actor: the IP, fingerprint, and user that attribute the new topic and its
  # first post.
  defp actor_attributes(%Actor{ip: ip, fingerprint: fingerprint, user: user}),
    do: [ip: ip, fingerprint: fingerprint, user: user]

  @doc """
  Seeds a new-topic changeset for `actor` (a `Philomena.Attribution.Actor` whose
  user may be `nil`) in the forum named by `forum_slug`.

  This is a read that precedes a create: a banned actor is rejected with
  `{:error, :ban}` first; the forum is then loaded by short name and authorized
  for `:show`. The returned changeset is seeded with an empty first post and a
  two-option poll so those nested fields are present.

  Returns `{:ok, {forum, changeset}}` (the forum is returned for the caller to
  reuse), `{:error, :ban}` for a banned actor, or `{:error, :unauthorized}` when
  the forum is not visible to `actor`.

  ## Examples

      iex> load_new_topic(actor, "dis")
      {:ok, {%Forum{}, %Ecto.Changeset{}}}

  """
  @spec load_new_topic(Actor.t(), String.t()) ::
          {:ok, {Forum.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized}
  def load_new_topic(%Actor{} = actor, forum_slug) do
    with :ok <- verify_not_banned(actor),
         {:ok, forum} <- load_authorized_forum(actor.user, forum_slug) do
      changeset =
        change_topic(%Topic{
          poll: %Poll{options: [%PollOption{}, %PollOption{}]},
          posts: [%Post{}]
        })

      {:ok, {forum, changeset}}
    end
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
  Sticks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor` (the acting user).

  The forum is loaded by short name and authorized for `:show`, the topic is
  loaded by slug (a hidden topic stays invisible unless the actor may `:show`
  it), and the `:hide` permission on the topic is then checked. On success a
  moderation log is written attributing the stick to the actor.

  Returns `{:ok, {forum, topic}}` on success (both are returned for the caller to reuse), `{:error, forum, topic}` when the stick changeset is rejected
  (unreachable in practice, since the changeset has no validation, but kept so
  the caller can still act on it), `{:error, :unauthorized}`
  when the actor may not see the forum/topic or stick the topic, or
  `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> stick_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec stick_topic(Actor.t(), String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def stick_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case stick_topic(topic) do
        {:ok, stuck_topic} ->
          # Body reads the title off the post-update topic; forum name off the
          # separately loaded forum. The log type and body strings are stored,
          # so keep them exact.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Stick:create",
            Paths.topic_path(forum, stuck_topic),
            "Stickied topic '#{stuck_topic.title}' in #{forum.name}"
          )

          {:ok, {forum, stuck_topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Makes a topic sticky, appearing at the top of its forum.

  This is the internal stick engine shared with `stick_topic/3`; it performs no
  authorization and writes no moderation log, so callers needing authorization and a moderation log go
  through `stick_topic/3`.

  ## Examples

      iex> stick_topic(topic)
      {:ok, %Topic{}}

  """
  def stick_topic(topic) do
    Topic.stick_changeset(topic)
    |> Repo.update()
  end

  @doc """
  Unsticks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor` (the acting user).

  Loading and authorization mirror `stick_topic/3` (`:show` on the forum,
  visibility on the topic, then `:hide` on the topic). On success a moderation
  log is written.

  Returns `{:ok, {forum, topic}}` on success, `{:error, forum, topic}` if the
  unstick is rejected (so the caller can act on it),
  `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unstick_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unstick_topic(Actor.t(), String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def unstick_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case unstick_topic(topic) do
        {:ok, unstuck_topic} ->
          # Body reads the title off the post-unstick topic; forum name off the
          # separately loaded forum. The log type and body strings are stored,
          # so keep them exact.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Stick:delete",
            Paths.topic_path(forum, unstuck_topic),
            "Unstickied topic '#{unstuck_topic.title}' in #{forum.name}"
          )

          {:ok, {forum, unstuck_topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Removes sticky status from a topic.

  Internal unstick engine shared with `unstick_topic/3`; it performs no
  authorization and writes no moderation log, so callers needing authorization and a moderation log go
  through `unstick_topic/3`.

  ## Examples

      iex> unstick_topic(topic)
      {:ok, %Topic{}}

  """
  def unstick_topic(topic) do
    Topic.unstick_changeset(topic)
    |> Repo.update()
  end

  @doc """
  Locks the topic named by `topic_slug` within the forum named by `forum_slug`,
  recording the lock reason from `topic_params`, on behalf of `actor` (the
  acting user).

  The forum is loaded by short name and authorized for `:show`, the topic is
  loaded by slug (a hidden topic stays invisible unless the actor may `:show`
  it), and the `:hide` permission on the topic is then checked. On success a
  moderation log is written attributing the lock to the actor.

  Returns `{:ok, {forum, topic}}` on success (both are returned for the caller to reuse), `{:error, forum, topic}` when the lock changeset is rejected
  (e.g. a blank reason, so the caller can still act on it), `{:error, :unauthorized}` when the actor may not see the forum/topic
  or lock the topic, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> lock_topic(moderator, "dis", "some-topic", %{"lock_reason" => "Off topic"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> lock_topic(moderator, "dis", "some-topic", %{"lock_reason" => ""})
      {:error, %Forum{}, %Topic{}}

  """
  @spec lock_topic(Actor.t(), String.t(), String.t(), map()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def lock_topic(%Actor{} = actor, forum_slug, topic_slug, topic_params) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case lock_topic(topic, topic_params, actor.user) do
        {:ok, locked_topic} ->
          # The body reads the reason and title off the post-update topic, and
          # the forum name off the separately loaded forum (the loaded topic
          # carries no preloaded `:forum`). The log type and body strings are
          # stored, so keep them exact.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Lock:create",
            Paths.topic_path(forum, locked_topic),
            "Locked topic '#{locked_topic.title}' (#{locked_topic.lock_reason}) in #{forum.name}"
          )

          {:ok, {forum, locked_topic}}

        {:error, %Ecto.Changeset{}} ->
          # The pre-update topic is returned for the caller to reuse.
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Locks a topic to prevent further posting.

  This is the internal lock engine shared with `lock_topic/4`; it performs no
  authorization and writes no moderation log, so callers needing authorization and a moderation log go
  through `lock_topic/4`.

  ## Examples

      iex> lock_topic(topic, %{"lock_reason" => "Off topic"}, user)
      {:ok, %Topic{}}

  """
  def lock_topic(%Topic{} = topic, attrs, user) do
    Topic.lock_changeset(topic, attrs, user)
    |> Repo.update()
  end

  @doc """
  Unlocks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor` (the acting user).

  Loading and authorization mirror `lock_topic/4` (`:show` on the forum,
  visibility on the topic, then `:hide` on the topic). On success a moderation
  log is written.

  Returns `{:ok, {forum, topic}}` on success, `{:error, forum, topic}` if the
  unlock is rejected (so the caller can act on it),
  `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unlock_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unlock_topic(Actor.t(), String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def unlock_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case unlock_topic(topic) do
        {:ok, unlocked_topic} ->
          # Body reads the title off the post-unlock topic; forum name off the
          # separately loaded forum. The log type and body strings are stored,
          # so keep them exact.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Lock:delete",
            Paths.topic_path(forum, unlocked_topic),
            "Unlocked topic '#{unlocked_topic.title}' in #{forum.name}"
          )

          {:ok, {forum, unlocked_topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Unlocks a topic to allow posting again.

  Internal unlock engine shared with `unlock_topic/3`; it performs no
  authorization and writes no moderation log, so callers needing authorization and a moderation log go
  through `unlock_topic/3`.

  ## Examples

      iex> unlock_topic(topic)
      {:ok, %Topic{}}

  """
  def unlock_topic(%Topic{} = topic) do
    Topic.unlock_changeset(topic)
    |> Repo.update()
  end

  @doc """
  Moves the topic named by `topic_slug` within the forum named by `forum_slug`
  to the forum identified by the `"target_forum_id"` key of `topic_params`, on
  behalf of `actor` (the acting user).

  The forum is loaded by short name and authorized for `:show`, the topic is
  loaded by slug (a hidden topic stays invisible unless the actor may `:show`
  it), and the `:hide` permission on the topic is then checked. Only after
  authorization is the target forum id parsed and the move attempted, so an
  unprivileged actor sending a malformed target still gets unauthorized. On
  success the NEW forum is preloaded (needed for the log body and for the caller
  to reuse), post/topic counts are updated for both forums, and a
  moderation log is written attributing the move to the actor.

  Returns `{:ok, {new_forum, topic}}` on success (the new forum is returned for
  the caller to reuse), `{:error, forum, topic}` carrying the SOURCE forum and
  topic when the move cannot happen (a missing or non-integer target id, or a
  well-formed
  id whose forum does not exist, caught by the `move_changeset` FK constraint
  and normalized to a changeset failure), `{:error, :unauthorized}` when the
  actor may not see the forum/topic or move the topic, or `{:error, :not_found}`
  when the topic does not exist.

  ## Examples

      iex> move_topic(moderator, "dis", "some-topic", %{"target_forum_id" => "3"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> move_topic(moderator, "dis", "some-topic", %{"target_forum_id" => "bogus"})
      {:error, %Forum{}, %Topic{}}

  """
  @spec move_topic(Actor.t(), String.t(), String.t(), map() | nil) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def move_topic(%Actor{} = actor, forum_slug, topic_slug, topic_params) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      # Target id parsing happens only after authorization, so an unprivileged
      # actor with a malformed target still answers unauthorized rather than the
      # bespoke failure. A missing or non-integer target and a well-formed id
      # for a nonexistent forum all funnel to the inner else, which returns
      # the SOURCE topic - so it carries the source `forum` and `topic`.
      with {:ok, target_forum_id} <- parse_target_forum_id(topic_params),
           {:ok, %{topic: moved_topic}} <- move_topic(topic, target_forum_id) do
        # Force-preload the NEW forum off the moved topic for the log body and
        # for the caller to reuse. The log type and body strings are stored,
        # so keep them exact.
        new_forum = Repo.preload(moved_topic, :forum, force: true).forum

        ModerationLogs.create_moderation_log(
          actor,
          "Topic.Move:create",
          Paths.topic_path(new_forum, moved_topic),
          "Topic '#{moved_topic.title}' moved to #{new_forum.name}"
        )

        {:ok, {new_forum, moved_topic}}
      else
        _ -> {:error, forum, topic}
      end
    end
  end

  # `nil` topic_params (the param was absent entirely) and a missing/non-integer
  # `target_forum_id` all collapse to `:error`.
  defp parse_target_forum_id(topic_params) do
    (topic_params || %{})
    |> Map.get("target_forum_id")
    |> IntegerId.parse()
  end

  @doc """
  Moves a topic to a different forum, updating post counts for both forums.

  This is the internal move engine shared with `move_topic/4`; it performs no
  authorization and writes no moderation log, so callers needing authorization and a moderation log go
  through `move_topic/4`.

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
  Hides the topic named by `topic_slug` within the forum named by `forum_slug`,
  recording `deletion_reason`, on behalf of `actor` (the acting user).

  The forum is loaded by short name and authorized for `:show`, the topic is
  loaded by slug (a topic already hidden stays invisible unless the actor may
  `:show` it), and the `:hide` permission on the topic is then checked. On success
  the forum post/topic counts are updated, the topic's posts are reindexed, and
  a moderation log is written attributing the deletion to the actor.

  Returns `{:ok, {forum, topic}}` on success (both are returned for the caller to reuse), `{:error, forum, topic}` when the hide changeset is rejected
  (e.g. a blank reason, so the caller can still act on it), `{:error, :unauthorized}` when the actor may not see the forum/topic
  or hide the topic, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> hide_topic(moderator, "dis", "some-topic", "Rule violation")
      {:ok, {%Forum{}, %Topic{}}}

      iex> hide_topic(moderator, "dis", "some-topic", "")
      {:error, %Forum{}, %Topic{}}

  """
  @spec hide_topic(Actor.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def hide_topic(%Actor{} = actor, forum_slug, topic_slug, deletion_reason) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case hide_topic(topic, deletion_reason, actor.user) do
        {:ok, hidden_topic} ->
          # The body reads the reason and title off the post-update topic, and
          # the forum name off the separately loaded forum (the loaded topic
          # carries no preloaded `:forum`). The log type and body strings are
          # stored, so keep them exact.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Hide:create",
            Paths.topic_path(forum, hidden_topic),
            "Deleted topic '#{hidden_topic.title}' (#{hidden_topic.deletion_reason}) in #{forum.name}"
          )

          {:ok, {forum, hidden_topic}}

        {:error, %Ecto.Changeset{}} ->
          # The pre-update topic is returned for the caller to reuse.
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Hides a topic and updates related forum data.

  This is the internal hide engine shared with `hide_topic/4` and
  `Philomena.Users.Eraser`; it performs no authorization and writes no
  moderation log, so callers needing authorization and a moderation log go through `hide_topic/4`.

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
  Restores the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor` (the acting user).

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
  @spec unhide_topic(Actor.t(), String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def unhide_topic(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case unhide_topic(topic) do
        {:ok, restored_topic} ->
          # Body reads the title off the post-restore topic; forum name off the
          # separately loaded forum. The log type and body strings are stored,
          # so keep them exact.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Hide:delete",
            Paths.topic_path(forum, restored_topic),
            "Restored topic '#{restored_topic.title}' in #{forum.name}"
          )

          {:ok, {forum, restored_topic}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Unhides a previously hidden topic.

  Internal restore engine shared with `unhide_topic/3`; it performs no
  authorization and writes no moderation log, so callers needing authorization and a moderation log go
  through `unhide_topic/3`.

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
  Updates the title of the topic named by `topic_slug` within the forum named by
  `forum_slug` from `topic_params`, on behalf of `actor` (a
  `Philomena.Attribution.Actor` whose user may be `nil` for an anonymous
  visitor).

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
  @spec update_topic_title(Actor.t(), String.t(), String.t(), map()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def update_topic_title(%Actor{} = actor, forum_slug, topic_slug, topic_params) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :edit, topic) do
      case update_topic_title(topic, topic_params) do
        {:ok, updated_topic} ->
          {:ok, {forum, updated_topic}}

        {:error, %Ecto.Changeset{}} ->
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Updates a topic's title.

  This is the internal title engine shared with `update_topic_title/4`; it
  performs no authorization, so callers needing authorization go through
  `update_topic_title/4`.

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
