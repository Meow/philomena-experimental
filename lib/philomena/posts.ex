defmodule Philomena.Posts do
  @moduledoc """
  The Posts context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Repo

  alias PhilomenaQuery.Search
  alias Philomena.Topics.Topic
  alias Philomena.Topics
  alias Philomena.Forums
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.UserStatistics
  alias Philomena.Users.User
  alias Philomena.Posts.Post
  alias Philomena.Posts.PostVersion
  alias Philomena.Posts
  alias Philomena.IndexWorker
  alias Philomena.Forums.Forum
  alias Philomena.Notifications
  alias Philomena.Versions
  alias Philomena.Reports
  alias Philomena.Reports.Report
  alias Philomena.RateLimiter
  alias Philomena.Attribution.Actor

  @post_create_window 15

  # Creates a post. Visible for testing.
  @doc false
  def create_post(topic, %Actor{user: user} = actor, params \\ %{}) do
    now = DateTime.utc_now(:second)

    topic_query =
      Topic
      |> where(id: ^topic.id)

    topic_lock_query =
      topic_query
      |> lock("FOR UPDATE")

    forum_query =
      Forum
      |> where(id: ^topic.forum_id)

    Multi.new()
    |> Multi.one(:topic, topic_lock_query)
    |> Multi.run(:post, fn repo, _ ->
      last_position =
        Post
        |> where(topic_id: ^topic.id)
        |> order_by(desc: :topic_position)
        |> select([p], p.topic_position)
        |> limit(1)
        |> repo.one()

      Ecto.build_assoc(topic, :posts, topic_position: (last_position || -1) + 1)
      |> Post.creation_changeset(params, actor)
      |> repo.insert()
    end)
    |> Multi.run(:update_topic, fn repo, %{post: %{id: post_id}} ->
      {count, nil} =
        repo.update_all(topic_query,
          inc: [post_count: 1],
          set: [last_post_id: post_id, last_replied_to_at: now]
        )

      {:ok, count}
    end)
    |> Multi.run(:update_forum, fn repo, %{post: %{id: post_id}} ->
      {count, nil} =
        repo.update_all(forum_query, inc: [post_count: 1], set: [last_post_id: post_id])

      {:ok, count}
    end)
    |> Multi.run(:notification, &notify_post/2)
    |> Topics.maybe_subscribe_on(:topic, user, :watch_on_reply)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} = result ->
        reindex_post(post)

        result

      error ->
        error
    end
  end

  # Updates a post. Visible for testing.
  @doc false
  def update_post(%Post{} = post, editor, attrs) do
    now = DateTime.utc_now(:second)
    post_changes = Post.changeset(post, attrs, now)

    Multi.new()
    |> Multi.update(:post, post_changes)
    |> Multi.run(:version, fn repo, %{post: updated} ->
      Versions.record_edit(repo, post, updated, editor)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} = result ->
        reindex_post(post)

        result

      error ->
        error
    end
  end

  # Hides an already-loaded post and handles associated reports. Visible for testing.
  @doc false
  def hide_loaded_post(%Post{} = post, attrs, user) do
    post = post |> Repo.preload(:topic)

    Multi.new()
    |> Multi.update(:post, Post.hide_changeset(post, attrs, user))
    |> Multi.update_all(:reports, Reports.close_report_query(user, post_id: post.id), [])
    |> Multi.update_all(:topic, Topics.update_topic_last_post_query(post.topic_id), [])
    |> Multi.update_all(:forum, Forums.update_forum_last_post_query(post.topic.forum_id), [])
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post, reports: {_count, reports}}} ->
        Reports.reindex_reports(reports)
        reindex_post(post)

        {:ok, post}

      error ->
        normalize_multi_error(error)
    end
  end

  # Unhides a previously hidden post.
  defp unhide_post(%Post{} = post) do
    post = post |> Repo.preload(:topic)

    Multi.new()
    |> Multi.update(:post, Post.unhide_changeset(post))
    |> Multi.update_all(:topic, Topics.update_topic_last_post_query(post.topic_id), [])
    |> Multi.update_all(:forum, Forums.update_forum_last_post_query(post.topic.forum_id), [])
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} ->
        reindex_post(post)

        {:ok, post}

      error ->
        error
    end
  end

  # Marks a post as destroyed and removes its text (hard deletion).
  #
  # This is the internal destroy engine shared with `destroy_post/2` and
  # `Philomena.Users.Eraser`.
  @doc false
  def destroy_post(%Post{} = post) do
    post = post |> Repo.preload([:topic, :user])

    Multi.new()
    |> Multi.update(:post, Post.destroy_changeset(post))
    |> Multi.update_all(
      :topic,
      Topic |> where(id: ^post.topic_id),
      inc: [post_count: -1]
    )
    |> Multi.update_all(
      :forum,
      Forum |> where(id: ^post.topic.forum_id),
      inc: [post_count: -1]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} ->
        UserStatistics.increment(post.user_id, :posts_count, -1)
        reindex_post(post)

        {:ok, post}

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking post changes.

  ## Examples

      iex> change_post(post)
      %Ecto.Changeset{source: %Post{}}

  """
  def change_post(%Post{} = post) do
    Post.changeset(post, %{})
  end

  @doc """
  Lists the publicly visible posts of a topic, on behalf of any requester.

  The topic is loaded by its `topic_slug` within the forum named by `forum_slug`,
  requiring the topic to be visible (not hidden from users) and the forum's access
  level to be `"normal"` - for every requester alike, so restricted forums are never
  exposed here. When the topic cannot be found under those constraints,
  `{:error, :not_found}` is returned.

  Otherwise the topic's posts are windowed by `pagination`'s page number and
  size over their `topic_position`, ordered ascending, with authors preloaded.
  Posts with destroyed content are excluded; posts merely hidden from users stay
  in the list. Each returned post carries the loaded topic so callers can read
  its post count for the response total.

  Returns `{:ok, {topic, posts}}` or `{:error, :not_found}`.

  ## Examples

      iex> list_public_topic_posts("dis", "some-topic", pagination)
      {:ok, {%Topic{}, [%Post{}, ...]}}

      iex> list_public_topic_posts("dis", "nonexistent", pagination)
      {:error, :not_found}

  """
  @spec list_public_topic_posts(
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          pagination :: map()
        ) ::
          {:ok, {Topic.t(), [Post.t()]}} | {:error, :not_found}
  def list_public_topic_posts(forum_slug, topic_slug, pagination) do
    # FIXME: Delete this function. Replace callers with actor-scoped version of this function.
    case public_topic(forum_slug, topic_slug) do
      nil ->
        {:error, :not_found}

      topic ->
        # FIXME: special case pagination structure. Use generic Repo.pagination_params()
        # and Scrivener.Page return
        %{page_number: page, page_size: page_size} = pagination

        posts =
          Post
          |> where(topic_id: ^topic.id)
          |> where(destroyed_content: false)
          |> where(
            [p],
            p.topic_position >= ^(page_size * (page - 1)) and
              p.topic_position < ^(page_size * page)
          )
          |> order_by(asc: :topic_position)
          |> preload(:user)
          |> Repo.all()
          |> Enum.map(&%{&1 | topic: topic})

        {:ok, {topic, posts}}
    end
  end

  @doc """
  Fetches a single publicly visible post of a topic, on behalf of any
  requester.

  `post_id` is integer-guarded first, so a non-integer id is reported as missing
  before any query runs. The post is then loaded by id within the topic named by
  `topic_slug` and the forum named by `forum_slug`, requiring the post to
  have non-destroyed content, the topic to be visible (not hidden from users),
  and the forum's access level to be `"normal"` - for every requester alike. The
  author and topic are preloaded. A hidden topic, a restricted forum, a slug
  under the wrong forum, a destroyed post, and an unknown id are all reported as
  missing.

  Returns `{:ok, post}` or `{:error, :not_found}`.

  ## Examples

      iex> load_public_topic_post("dis", "some-topic", "1")
      {:ok, %Post{}}

      iex> load_public_topic_post("dis", "some-topic", "not-a-number")
      {:error, :not_found}

  """
  @spec load_public_topic_post(
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          post_id :: Loader.integer_id()
        ) ::
          {:ok, Post.t()} | {:error, :not_found}
  def load_public_topic_post(forum_slug, topic_slug, post_id) do
    # FIXME: Delete this function. Replace callers with actor-scoped version of this function.
    case IntegerId.parse(post_id) do
      {:ok, post_id} ->
        Post
        |> join(:inner, [p], _ in assoc(p, :topic))
        |> join(:inner, [_p, t], _ in assoc(t, :forum))
        |> where(id: ^post_id)
        |> where(destroyed_content: false)
        |> where([_p, t], t.hidden_from_users == false and t.slug == ^topic_slug)
        |> where([_p, _t, f], f.access_level == "normal" and f.short_name == ^forum_slug)
        |> preload([:user, :topic])
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          post -> {:ok, post}
        end

      :error ->
        {:error, :not_found}
    end
  end

  # Loads a topic by slug within the named forum, requiring the topic to be
  # visible and the forum's access level to be `"normal"` - for every
  # requester alike. Returns the topic or `nil`.
  defp public_topic(forum_slug, topic_slug) do
    Topic
    |> join(:inner, [t], _ in assoc(t, :forum))
    |> where([t], t.hidden_from_users == false and t.slug == ^topic_slug)
    |> where([_t, f], f.access_level == "normal" and f.short_name == ^forum_slug)
    |> Repo.one()
  end

  @doc """
  Fetches a single publicly visible post by `post_id`, on behalf of any
  requester.

  The post is loaded by id, requiring non-destroyed content, a topic that is not
  hidden from users, and a forum whose access level is `"normal"` - for every
  requester alike, so posts in restricted forums or hidden topics are never
  exposed here. The author and topic are preloaded. A destroyed post, a post in
  a hidden topic, a post in a restricted forum, and an unknown id are all
  reported as missing.

  `post_id` is interpolated into the query without being integer-guarded, so an
  uncastable id surfaces as an `Ecto.Query.CastError` rather than a missing
  resource.

  Returns `{:ok, post}` or `{:error, :not_found}`.

  ## Examples

      iex> load_public_post("1")
      {:ok, %Post{}}

      iex> load_public_post("999999999")
      {:error, :not_found}

  """
  @spec load_public_post(Loader.integer_id()) :: {:ok, Post.t()} | {:error, :not_found}
  def load_public_post(post_id) do
    # FIXME: Delete this function. Replace callers with actor-scoped version of this function.
    Post
    |> join(:inner, [p], _ in assoc(p, :topic))
    |> join(:inner, [_p, t], _ in assoc(t, :forum))
    |> where(id: ^post_id)
    |> where(destroyed_content: false)
    |> where([_p, t], t.hidden_from_users == false)
    |> where([_p, _t, f], f.access_level == "normal")
    |> preload([:user, :topic])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      post -> {:ok, post}
    end
  end

  @doc """
  Searches the publicly visible posts on behalf of `actor`, applying the
  compiled query string `query_string` and `pagination`, sorted newest first.

  The actor's user scopes what the compiled query may match, but the results
  are further restricted to posts that are not hidden from users and that
  belong to a forum whose access level is `"normal"` - for every requester
  alike, so hidden posts and posts in restricted forums are never returned or
  counted. Results are
  preloaded. An empty or missing query string compiles to a match on
  nothing, yielding an empty page rather than an error.

  Returns `{:ok, results}`, or `{:error, msg}` when `query_string` fails to
  compile.

  ## Examples

      iex> search_public_posts(actor, "chartreuse", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_public_posts(actor, ")", pagination)
      {:error, "Imbalanced parentheses."}

  """
  @spec search_public_posts(Actor.t(), String.t() | nil, Search.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, String.t()}
  def search_public_posts(%Actor{user: user}, query_string, pagination) do
    # FIXME: Delete this function. Replace callers with actor-scoped version of this function.
    case Posts.Query.compile(query_string, user: user) do
      {:ok, query} ->
        results =
          Post
          |> Search.search_definition(
            %{
              query: %{
                bool: %{
                  must: [
                    query,
                    %{term: %{hidden_from_users: false}},
                    %{term: %{access_level: "normal"}}
                  ]
                }
              },
              sort: %{created_at: :desc}
            },
            pagination
          )
          |> Search.search_records(preload(Post, [:user, :topic]))

        {:ok, results}

      {:error, msg} ->
        {:error, msg}
    end
  end

  defp notify_post(_repo, %{post: post, topic: topic}) do
    Notifications.create_forum_post_notification(post.user, topic, post)
  end

  @doc """
  Creates a reply on behalf of `actor` in the topic named by `topic_slug`
  within the forum named by `forum_slug`, from `post_params`.

  `actor`'s write access is verified first. Then the forum is
  loaded by short name and authorized for `:show`, the topic is loaded by slug
  with hidden topics kept invisible unless the actor may `:show` them, and the
  actor is authorized for `:create_post` on the topic (which no rule permits on a
  locked or hidden topic). The reply is then inserted.

  On a successful insert, an approved post increments its author's forum post
  count and an unapproved one is reported for containing external links. The
  returned map carries the post, topic, and forum needed for the firehose
  broadcast and for the caller to reuse.

  ## Return shapes

  - `{:ok, %{post: post, topic: topic, forum: forum}}` on success
  - `{:error, forum, topic}` when the insert is rejected (both carry the topic for the caller to reuse)
  - `{:error, :ban}` or `{:error, :unauthorized}` from the write-access check
  - `{:error, :unauthorized}` when the forum or topic is not visible or the topic may not be posted in
  - `{:error, :not_found}` when the topic does not exist
  - `{:error, :rate_limited}` when a non-exempt actor has posted within the last 15 seconds

  ## Examples

      iex> create_post(actor, "dis", "some-topic", %{"body" => "Hi"})
      {:ok, %{post: %Post{}, topic: %Topic{}, forum: %Forum{}}}

      iex> create_post(actor, "dis", "some-topic", %{"body" => ""})
      {:error, %Forum{}, %Topic{}}

  """
  @spec create_post(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          post_params :: map() | nil
        ) ::
          {:ok, %{post: Post.t(), topic: Topic.t(), forum: Forum.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found | :rate_limited}
  def create_post(%Actor{} = actor, forum_slug, topic_slug, post_params) do
    with :ok <- verify_write_access(actor),
         :ok <- RateLimiter.check_rate_limit(actor, :post_create),
         {:ok, forum, topic} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor.user, :create_post, topic) do
      case create_post(topic, actor, post_params || %{}) do
        {:ok, %{post: post}} ->
          RateLimiter.record_action(actor, :post_create, @post_create_window)
          record_post_creation(actor, post)
          # The firehose broadcast needs the topic's author, so the topic
          # carries its `:user` here.
          # FIXME: we call broadcast elsewhere in Philomena namespace but not here? Why was it not moved?
          {:ok, %{post: post, topic: Repo.preload(topic, :user), forum: forum}}

        _error ->
          {:error, forum, topic}
      end
    end
  end

  # Post-insert bookkeeping: an approved post counts toward its author's forum
  # post total (a no-op for an anonymous author, whose user is nil), an
  # unapproved one is reported for external links.
  defp record_post_creation(%Actor{user: user}, %Post{approved: true}),
    do: UserStatistics.increment(user, :posts_count)

  defp record_post_creation(_actor, post),
    do: report_non_approved(post)

  @doc """
  Creates a system report for non-approved posts containing external images.
  Returns false for already approved posts.

  ## Returns
  - `false`: If the post is already approved
  - `{:ok, %Report{}}`: If a system report was created

  ## Examples

      iex> report_non_approved(approved_post)
      false

      iex> report_non_approved(unapproved_post)
      {:ok, %Report{}}

  """
  def report_non_approved(%Post{approved: true}), do: false

  def report_non_approved(post) do
    Reports.create_system_report(
      "Approval",
      "Post contains external links",
      post_id: post.id
    )
  end

  @doc """
  Loads the post named by `post_id` within the topic named by
  `topic_slug` in the forum named by `forum_slug` for editing, on behalf of
  `actor`.

  A banned actor is rejected with `{:error, :ban}` first, but the fingerprint requirement
  that the write itself enforces does not apply here. The forum, topic, and post are then loaded
  and authorized (see `load_editable_post/4`).

  Returns `{:ok, {post, changeset}}` - the post (with its topic, forum, and
  author preloaded) and a change-tracking changeset for it -
  `{:error, :ban}` for a banned actor, `{:error, :unauthorized}` when the forum,
  topic, or post is not visible or may not be edited, or `{:error, :not_found}`
  when the topic or post does not exist.

  ## Examples

      iex> load_post_for_edit(actor, "dis", "some-topic", "1")
      {:ok, {%Post{}, %Ecto.Changeset{}}}

  """
  @spec load_post_for_edit(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          Loader.integer_id()
        ) ::
          {:ok, {Post.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_post_for_edit(actor, forum_slug, topic_slug, post_id) do
    with :ok <- verify_write_access(actor),
         {:ok, post} <- load_editable_post(actor, forum_slug, topic_slug, post_id) do
      {:ok, {post, change_post(post)}}
    end
  end

  @doc """
  Updates the post named by `post_id` within the topic named by
  `topic_slug` in the forum named by `forum_slug` from `post_params`, on behalf
  of `actor`.

  `actor`'s write access is verified first, before the same load-and-authorize chain
  `load_post_for_edit/4` uses (see `load_editable_post/4`). The edit is then applied
  by `update_post/3`, recording a version attributed to `actor`'s user; an unapproved
  result is reported for containing external links (an approved result is a no-op).

  ## Return shapes

  - `{:ok, post}` on success (the post carries its topic and forum for the caller to reuse)
  - `{:error, {post, changeset}}` when the edit is rejected
  - `{:error, :ban}` or `{:error, :unauthorized}` from the write-access check
  - `{:error, :unauthorized}` when the forum, topic, or post is not visible or may not be edited
  - `{:error, :not_found}` when the topic or post does not exist

  ## Examples

      iex> update_post(actor, "dis", "some-topic", "1", %{"body" => "Edited"})
      {:ok, %Post{}}

      iex> update_post(actor, "dis", "some-topic", "1", %{"body" => ""})
      {:error, {%Post{}, %Ecto.Changeset{}}}

  """
  @spec update_post(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          post_id :: Loader.integer_id(),
          post_params :: map() | nil
        ) ::
          {:ok, Post.t()}
          | {:error, {Post.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def update_post(%Actor{} = actor, forum_slug, topic_slug, post_id, post_params) do
    with :ok <- verify_write_access(actor),
         {:ok, post} <- load_editable_post(actor, forum_slug, topic_slug, post_id) do
      case update_post(post, actor.user, post_params || %{}) do
        {:ok, %{post: updated_post}} ->
          report_non_approved(updated_post)
          {:ok, updated_post}

        {:error, :post, changeset, _changes} ->
          {:error, {post, changeset}}
      end
    end
  end

  # Load-and-authorize chain shared by the edit and update actions, in order: the
  # forum is authorized for `:show` and the topic loaded (a hidden topic needs
  # `:show`), the actor is authorized for `:create_post` on the topic, the post is
  # loaded within the topic (a missing row is `{:error, :not_found}`, a post
  # hidden from users needs `:show`), and finally the post is authorized for
  # `:edit`. The `:create_post` check precedes the post load, so a locked topic
  # answers unauthorized before an unknown id could answer not-found.
  defp load_editable_post(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with {:ok, _forum, topic} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :create_post, topic),
         {:ok, post} <- load_topic_post(actor, topic, post_id),
         :ok <- authorize(actor, :edit, post) do
      {:ok, post}
    end
  end

  @doc """
  Hides the post named by `post_id`, recording the
  `"deletion_reason"` carried in `post_params`, on behalf of `actor`.

  The post is authorized for `:hide`. On success, the post's
  associated reports are closed, the topic's and forum's last-post pointers are
  refreshed, the post is reindexed, and a moderation log is written attributing
  the deletion to `actor`.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can reuse them for either outcome.
  A rejected hide changeset (e.g. a blank deletion reason) returns
  `{:error, %Post{}}` carrying the loaded post.

  ## Examples

      iex> hide_post(moderator, "1", %{"deletion_reason" => "Spam"})
      {:ok, %Post{}}

      iex> hide_post(moderator, "1", %{"deletion_reason" => ""})
      {:error, %Post{}}

      iex> hide_post(user, "1", %{"deletion_reason" => "Spam"})
      {:error, :unauthorized}

  """
  @spec hide_post(Actor.t(), Loader.integer_id(), map()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def hide_post(%Actor{} = actor, post_id, post_params) do
    case IntegerId.parse(post_id) do
      {:ok, id} ->
        post =
          Post
          |> preload([:topic, topic: :forum])
          |> Repo.get(id)

        with :ok <- authorize(actor, :hide, post) do
          hide_authorized_post(actor, post, post_params)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp hide_authorized_post(actor, %Post{} = post, post_params) do
    case hide_loaded_post(post, post_params, actor.user) do
      {:ok, hidden_post} ->
        log_post_hide(actor, hidden_post)
        {:ok, hidden_post}

      {:error, %Ecto.Changeset{}} ->
        {:error, post}
    end
  end

  defp log_post_hide(actor, %Post{topic: topic} = post) do
    ModerationLogs.create_moderation_log(
      actor,
      "Topic.Post.Hide:create",
      Paths.forum_post_path(post),
      "Deleted forum post ##{post.id} in topic '#{topic.title}' (#{post.deletion_reason})"
    )
  end

  @doc """
  Restores the post named by `post_id`, on behalf of `actor`.

  Loading and authorization mirror `hide_post/3`. On success the topic's and
  forum's last-post pointers are refreshed, the post is reindexed, and a
  moderation log is written attributing the restore to `actor`.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can reuse them. A rejected restore
  returns `{:error, %Post{}}` carrying the loaded post.

  ## Examples

      iex> unhide_post(moderator, "1")
      {:ok, %Post{}}

      iex> unhide_post(user, "1")
      {:error, :unauthorized}

  """
  @spec unhide_post(Actor.t(), Loader.integer_id()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def unhide_post(%Actor{} = actor, post_id) do
    case IntegerId.parse(post_id) do
      {:ok, id} ->
        post =
          Post
          |> preload([:topic, topic: :forum])
          |> Repo.get(id)

        with :ok <- authorize(actor, :hide, post) do
          unhide_authorized_post(actor, post)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp unhide_authorized_post(actor, %Post{} = post) do
    case unhide_post(post) do
      {:ok, restored_post} ->
        log_post_unhide(actor, restored_post)
        {:ok, restored_post}

      _error ->
        {:error, post}
    end
  end

  defp log_post_unhide(actor, %Post{topic: topic} = post) do
    ModerationLogs.create_moderation_log(
      actor,
      "Topic.Post.Hide:delete",
      Paths.forum_post_path(post),
      "Restored forum post ##{post.id} in topic '#{topic.title}'"
    )
  end

  @doc """
  Destroys (permanently wipes the text of) the post named by
  `post_id`, on behalf of `actor`.

  The post is authorized for `:hide`. On success, the post's
  text is blanked, the topic's and forum's post counts and the author's forum
  post count are decremented, the post is reindexed, and a moderation log is
  written attributing the destruction to `actor`.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can reuse them for either outcome.
  A failed destroy returns `{:error, %Post{}}` carrying the loaded post.

  ## Examples

      iex> destroy_post(moderator, "1")
      {:ok, %Post{}}

      iex> destroy_post(user, "1")
      {:error, :unauthorized}

      iex> destroy_post(moderator, "not-an-integer")
      {:error, :not_found}

  """
  @spec destroy_post(Actor.t(), Loader.integer_id()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def destroy_post(%Actor{} = actor, post_id) do
    case IntegerId.parse(post_id) do
      {:ok, id} ->
        post =
          Post
          |> preload([:topic, topic: :forum])
          |> Repo.get(id)

        with :ok <- authorize(actor, :hide, post) do
          destroy_authorized_post(actor, post)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp destroy_authorized_post(actor, %Post{} = post) do
    case destroy_post(post) do
      {:ok, destroyed_post} ->
        log_post_destroy(actor, destroyed_post)
        {:ok, destroyed_post}

      _error ->
        {:error, post}
    end
  end

  defp log_post_destroy(actor, %Post{topic: topic} = post) do
    ModerationLogs.create_moderation_log(
      actor,
      "Topic.Post.Delete:create",
      Paths.forum_post_path(post),
      "Destroyed forum post ##{post.id} in topic '#{topic.title}'"
    )
  end

  @doc """
  Approves the post named by `post_id`, on behalf of `actor`.

  The post is authorized for `:approve`. On success, the post's associated
  reports are closed, the author's forum post count is incremented, the post
  is reindexed, and a moderation log is written attributing the approval to `actor`.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can reuse them for either outcome. A failed approval
  changeset returns `{:error, %Post{}}` carrying the loaded post.

  ## Examples

      iex> approve_post(moderator, "1")
      {:ok, %Post{}}

      iex> approve_post(user, "1")
      {:error, :unauthorized}

      iex> approve_post(moderator, "not-an-integer")
      {:error, :not_found}

  """
  @spec approve_post(Actor.t(), Loader.integer_id()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def approve_post(%Actor{} = actor, post_id) do
    case IntegerId.parse(post_id) do
      {:ok, id} ->
        post =
          Post
          |> preload([:topic, topic: :forum])
          |> Repo.get(id)

        with :ok <- authorize(actor, :approve, post) do
          approve_loaded_post(actor, post)
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp approve_loaded_post(%Actor{user: user} = actor, %Post{} = post) do
    report_query = Reports.close_report_query(user, post_id: post.id)
    changeset = Post.approve_changeset(post)

    Multi.new()
    |> Multi.update(:post, changeset)
    |> Multi.update_all(:reports, report_query, [])
    |> Repo.transaction()
    |> case do
      {:ok, %{post: approved_post, reports: {_count, reports}}} ->
        UserStatistics.increment(approved_post.user_id, :posts_count)
        Reports.reindex_reports(reports)
        reindex_post(approved_post)
        log_post_approval(actor, approved_post)

        {:ok, approved_post}

      _error ->
        # The approval changeset sets a boolean unconditionally, so this branch
        # is not reachable today; it carries the loaded post so a caller can
        # still act on it if that ever changes.
        {:error, post}
    end
  end

  defp log_post_approval(actor, %Post{topic: topic} = post) do
    ModerationLogs.create_moderation_log(
      actor,
      "Topic.Post.Approve:create",
      Paths.forum_post_path(post),
      "Approved forum post ##{post.id} in topic '#{topic.title}'"
    )
  end

  @doc """
  Loads the edit history of the post named by `post_id` within
  the topic named by `topic_slug` in the forum named by `forum_slug`, on behalf
  of `actor`. This is a public read with no ban check.

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them.
  The post is then loaded by id within that topic: a missing post is
  `{:error, :not_found}`, and a post hidden from users is visible only when
  `actor` may `:show` it, otherwise `{:error, :unauthorized}`. The post id is not
  integer-guarded before the query, so a non-integer id raises
  `Ecto.Query.CastError`. (FIXME.)

  On success the loaded post (with its topic, forum, and author associations
  preloaded) is returned alongside the topic
  and the last 25 versions of the post, newest first, with diffs and version
  authors resolved.

  Returns `{:ok, {topic, post, versions}}`, `{:error, :unauthorized}` when the
  forum, topic, or hidden post is not visible to `actor`, or
  `{:error, :not_found}` when the topic or post does not exist.

  ## Examples

      iex> post_history(user, "dis", "some-topic", "1")
      {:ok, {%Topic{}, %Post{}, [%Version{}, ...]}}

      iex> post_history(user, "dis", "some-topic", "999999999")
      {:error, :not_found}

  """
  @spec post_history(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          post_id :: Loader.integer_id()
        ) ::
          {:ok, {Topic.t(), Post.t(), [PostVersion.t()]}}
          | {:error, :unauthorized | :not_found}
  def post_history(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with {:ok, _forum, topic} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         {:ok, post} <- load_topic_post(actor, topic, post_id) do
      {:ok, {topic, post, Versions.load_post_versions(post)}}
    end
  end

  # The post is loaded by id scoped to the topic (with its topic, forum, and
  # author preloaded), a missing row is `{:error, :not_found}`,
  # and a post hidden from users is authorized for `:show` - visible to staff,
  # otherwise `{:error, :unauthorized}`.
  defp load_topic_post(%Actor{} = actor, topic, post_id) do
    Post
    |> where(topic_id: ^topic.id, id: ^to_string(post_id))
    |> preload(topic: :forum, user: [awards: :badge])
    |> Repo.one()
    |> authorize_post_visibility(actor)
  end

  defp authorize_post_visibility(nil, _actor),
    do: {:error, :not_found}

  defp authorize_post_visibility(%Post{hidden_from_users: false} = post, _actor),
    do: {:ok, post}

  defp authorize_post_visibility(%Post{} = post, actor) do
    with :ok <- authorize(actor, :show, post) do
      {:ok, post}
    end
  end

  @doc """
  Loads the post named by `post_id` within the topic named by
  `topic_slug` in the forum named by `forum_slug` for reporting, on behalf
  of `actor`.

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them.
  The post is then loaded by id within that topic: a missing post is
  `{:error, :not_found}`, and a post hidden from users is visible only when
  `actor` may `:show` it, otherwise `{:error, :unauthorized}`. The post id is not
  integer-guarded before the query, so a non-integer id raises
  `Ecto.Query.CastError`. (FIXME.)

  Returns `{:ok, {topic, post, changeset}}` - the topic (with its forum
  preloaded), the post, and a changeset for reporting the post -
  `{:error, :ban}` for a banned actor,
  `{:error, :unauthorized}` when the forum, topic, or hidden post is not visible,
  or `{:error, :not_found}` when the topic or post does not exist.

  ## Examples

      iex> load_post_for_report(actor, "dis", "some-topic", "1")
      {:ok, {%Topic{}, %Post{}, %Ecto.Changeset{}}}

  """
  @spec load_post_for_report(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          Loader.integer_id()
        ) ::
          {:ok, {Topic.t(), Post.t(), Ecto.Changeset.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_post_for_report(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with :ok <- verify_write_access(actor),
         {:ok, {topic, post}} <-
           load_reportable_post(actor, forum_slug, topic_slug, post_id) do
      changeset = Reports.change_report(%Report{post_id: post.id})
      {:ok, {topic, post, changeset}}
    end
  end

  @doc """
  Loads the post named by `post_id` within the topic named by
  `topic_slug` in the forum named by `forum_slug` for creating its report, on
  behalf of `actor`.

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them.
  The post is then loaded by id within that topic: a missing post is
  `{:error, :not_found}`, and a post hidden from users is visible only when
  `actor` may `:show` it, otherwise `{:error, :unauthorized}`. The post id is not
  integer-guarded before the query, so a non-integer id raises
  `Ecto.Query.CastError`. (FIXME.)

  Returns `{:ok, {topic, post}}` - the topic (with its forum preloaded) and post
  - `{:error, :ban}` or
  `{:error, :unauthorized}` from the write-access check, `{:error, :unauthorized}`
  when the forum, topic, or hidden post is not visible, or `{:error, :not_found}`
  when the topic or post does not exist.

  FIXME: this function looks like a duplicate of the one above?

  ## Examples

      iex> load_post_for_report_creation(actor, "dis", "some-topic", "1")
      {:ok, {%Topic{}, %Post{}}}

  """
  @spec load_post_for_report_creation(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          Loader.integer_id()
        ) ::
          {:ok, {Topic.t(), Post.t()}}
          | {:error, :ban | :unauthorized | :not_found}
  def load_post_for_report_creation(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with :ok <- verify_write_access(actor) do
      load_reportable_post(actor, forum_slug, topic_slug, post_id)
    end
  end

  # Shared forum/topic/post load-and-authorize chain for the report actions,
  # reproducing `post_history/4`'s chain (forum `:show`, topic visibility, and a
  # post hidden from users visible only to `user` when they may `:show` it).
  # Permissions are decided on the user alone, so the report loaders pass the
  # actor's user here. The post is loaded with its topic and forum preloaded, so
  # the topic returned here carries its forum.
  defp load_reportable_post(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with {:ok, _forum, topic} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         {:ok, post} <- load_topic_post(actor, topic, post_id) do
      {:ok, {post.topic, post}}
    end
  end

  @doc """
  Updates post search indices when a user's name changes.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  def user_name_reindex(old_name, new_name) do
    data = Posts.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Post, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Queues a single post for search index updates.
  Returns the post struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_comment(post)
      %Post{}

  """
  def reindex_post(%Post{} = post) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Posts", "id", [post.id]])

    post
  end

  @doc """
  Queues every post in the given topic for search index updates.

  Used when a topic's visibility changes: a post's indexed `hidden_from_users`
  reflects its topic's hidden state (see `Philomena.Posts.SearchIndex`), so
  hiding or unhiding a topic must refresh all of its posts.

  ## Examples

      iex> reindex_posts_in_topic(topic_id)
      :ok

  """
  def reindex_posts_in_topic(topic_id) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Posts", "topic_id", [topic_id]])

    :ok
  end

  @doc """
  Provides preload queries for post indexing operations.

  ## Examples

      iex> indexing_preloads()
      [user: user_query, topic: topic_query]

  """
  def indexing_preloads do
    user_query = select(User, [u], map(u, [:id, :name]))

    topic_query =
      Topic
      |> select([t], struct(t, [:forum_id, :title, :hidden_from_users]))
      |> preload([:forum])

    [
      user: user_query,
      topic: topic_query,
      deleted_by: user_query
    ]
  end

  @doc """
  Performs a search reindex operation on posts matching the given criteria.

  ## Parameters
  - column: The database column to filter on (e.g., :id, :topic_id)
  - condition: A list of values to match against the column

  ## Examples

      iex> perform_reindex(:id, [1, 2, 3])
      :ok

      iex> perform_reindex(:topic_id, [123])
      :ok

  """
  def perform_reindex(column, condition) do
    Post
    |> preload(^indexing_preloads())
    |> where([p], field(p, ^column) in ^condition)
    |> Search.reindex(Post)
  end

  # `Repo.transaction/1` reports a failed step as `{:error, name, value, changes}`.
  # Callers only ever want the changeset that failed, in the shape every other
  # context function returns it.
  defp normalize_multi_error({:error, _name, %Ecto.Changeset{} = changeset, _changes}),
    do: {:error, changeset}

  defp normalize_multi_error(result), do: result
end
