defmodule Philomena.Posts do
  @moduledoc """
  The Posts context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]
  alias Ecto.Multi
  alias Philomena.Repo

  alias PhilomenaQuery.Search
  alias Philomena.Topics.Topic
  alias Philomena.Topics
  alias Philomena.Forums
  alias Philomena.IntegerId
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.UserStatistics
  alias Philomena.Users.User
  alias Philomena.Posts.Post
  alias Philomena.Posts
  alias Philomena.IndexWorker
  alias Philomena.Forums.Forum
  alias Philomena.Notifications
  alias Philomena.Versions
  alias Philomena.Versions.Version
  alias Philomena.Reports

  @doc """
  Gets a single post.

  Raises `Ecto.NoResultsError` if the Post does not exist.

  ## Examples

      iex> get_post!(123)
      %Post{}

      iex> get_post!(456)
      ** (Ecto.NoResultsError)

  """
  def get_post!(id), do: Repo.get!(Post, id)

  @doc """
  Creates a post.

  ## Examples

      iex> create_post(%{field: value})
      {:ok, %Post{}}

      iex> create_post(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_post(topic, attributes, params \\ %{}) do
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

      Ecto.build_assoc(topic, :posts, [topic_position: (last_position || -1) + 1] ++ attributes)
      |> Post.creation_changeset(params, attributes)
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
    |> Topics.maybe_subscribe_on(:topic, attributes[:user], :watch_on_reply)
    |> Repo.transaction()
    |> case do
      {:ok, %{post: post}} = result ->
        reindex_post(post)

        result

      error ->
        error
    end
  end

  defp notify_post(_repo, %{post: post, topic: topic}) do
    Notifications.create_forum_post_notification(post.user, topic, post)
  end

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
      {"Post", post.id},
      "Approval",
      "Post contains external links"
    )
  end

  @doc """
  Updates a post.

  ## Examples

      iex> update_post(post, %{field: new_value})
      {:ok, %Post{}}

      iex> update_post(post, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_post(%Post{} = post, editor, attrs) do
    now = DateTime.utc_now(:second)
    current_body = post.body
    current_reason = post.edit_reason

    post_changes = Post.changeset(post, attrs, now)

    Multi.new()
    |> Multi.update(:post, post_changes)
    |> Multi.run(:version, fn _repo, _changes ->
      Versions.create_version("Post", post.id, editor.id, %{
        "body" => current_body,
        "edit_reason" => current_reason
      })
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

  @doc """
  Deletes a Post.

  ## Examples

      iex> delete_post(post)
      {:ok, %Post{}}

      iex> delete_post(post)
      {:error, %Ecto.Changeset{}}

  """
  def delete_post(%Post{} = post) do
    Repo.delete(post)
  end

  @doc """
  Hides the post named by the raw request `post_id`, recording the
  `"deletion_reason"` carried in `post_params`, on behalf of `actor` (a user, or
  `nil` for an anonymous visitor).

  Authorization (`:hide` on the loaded post) happens here; on success the post's
  associated reports are closed, the topic's and forum's last-post pointers are
  refreshed, the post is reindexed, and a moderation log is written attributing
  the deletion to `actor`. An id that cannot name a row is `{:error, :not_found}`,
  while a well-formed id that names no row authorizes `nil` - which no rule
  permits - and is therefore `{:error, :unauthorized}`, preserving the behavior
  of the load-then-authorize plug this replaces.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can build the post-anchor redirect for either outcome.
  A rejected hide changeset (e.g. a blank deletion reason) returns
  `{:error, %Post{}}` carrying that loaded post.

  ## Examples

      iex> hide_post(moderator, "1", %{"deletion_reason" => "Spam"})
      {:ok, %Post{}}

      iex> hide_post(moderator, "1", %{"deletion_reason" => ""})
      {:error, %Post{}}

      iex> hide_post(user, "1", %{"deletion_reason" => "Spam"})
      {:error, :unauthorized}

  """
  @spec hide_post(User.t() | nil, any(), map()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def hide_post(actor, post_id, post_params) do
    case IntegerId.parse(post_id) do
      {:ok, id} ->
        post =
          Post
          |> preload([:topic, topic: :forum])
          |> Repo.get(id)

        with :ok <- authorize(actor, :hide, post) do
          case hide_loaded_post(post, post_params, actor) do
            {:ok, hidden_post} ->
              log_post_hide(actor, hidden_post)
              {:ok, hidden_post}

            {:error, %Ecto.Changeset{}} ->
              {:error, post}
          end
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Hides an already-loaded post and handles associated reports.

  This is the internal hide engine shared with `hide_post/3` and
  `Philomena.Users.Eraser`; it performs no authorization and writes no
  moderation log, so controller-facing callers go through `hide_post/3`.

  ## Examples

      iex> hide_loaded_post(post, %{staff_note: "Rule violation"}, user)
      {:ok, %Post{}}

      iex> hide_loaded_post(post, %{deletion_reason: ""}, user)
      {:error, %Ecto.Changeset{}}

  """
  def hide_loaded_post(%Post{} = post, attrs, user) do
    post = post |> Repo.preload(:topic)

    Multi.new()
    |> Multi.update(:post, Post.hide_changeset(post, attrs, user))
    |> Multi.update_all(:reports, Reports.close_report_query({"Post", post.id}, user), [])
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

  defp log_post_hide(actor, %Post{topic: topic} = post) do
    ModerationLogs.create_moderation_log(
      actor,
      "Topic.Post.Hide:create",
      Paths.forum_post_path(post),
      "Deleted forum post ##{post.id} in topic '#{topic.title}' (#{post.deletion_reason})"
    )
  end

  @doc """
  Restores the post named by the raw request `post_id`, on behalf of `actor`
  (a user, or `nil` for an anonymous visitor).

  Loading and authorization mirror `hide_post/3` (`:hide` on the loaded post -
  a moderator can still see the hidden post here). On success the topic's and
  forum's last-post pointers are refreshed, the post is reindexed, and a
  moderation log is written attributing the restore to `actor`. An id that
  cannot name a row is `{:error, :not_found}`; a well-formed id naming no row
  authorizes `nil` and is `{:error, :unauthorized}`.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can build the post-anchor redirect. A rejected restore
  returns `{:error, %Post{}}` carrying that loaded post.

  ## Examples

      iex> unhide_post(moderator, "1")
      {:ok, %Post{}}

      iex> unhide_post(user, "1")
      {:error, :unauthorized}

  """
  @spec unhide_post(User.t() | nil, any()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def unhide_post(actor, post_id) do
    case IntegerId.parse(post_id) do
      {:ok, id} ->
        post =
          Post
          |> preload([:topic, topic: :forum])
          |> Repo.get(id)

        with :ok <- authorize(actor, :hide, post) do
          case unhide_post(post) do
            {:ok, restored_post} ->
              log_post_unhide(actor, restored_post)
              {:ok, restored_post}

            _error ->
              {:error, post}
          end
        end

      :error ->
        {:error, :not_found}
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
  Unhides a previously hidden post.

  This is the internal restore engine shared with `unhide_post/2`; it performs
  no authorization and writes no moderation log, so controller-facing callers go
  through `unhide_post/2`.

  ## Examples

      iex> unhide_post(post)
      {:ok, %Post{}}

  """
  def unhide_post(%Post{} = post) do
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

  @doc """
  Destroys (permanently wipes the text of) the post named by the raw request
  `post_id`, on behalf of `actor` (a user, or `nil` for an anonymous visitor).

  Authorization (`:hide` on the loaded post) happens here; on success the post's
  text is blanked, the topic's and forum's post counts and the author's forum
  post count are decremented, the post is reindexed, and a moderation log is
  written attributing the destruction to `actor`. An id that cannot name a row is
  `{:error, :not_found}`, while a well-formed id that names no row authorizes
  `nil` - which no rule permits - and is therefore `{:error, :unauthorized}`,
  preserving the behavior of the load-then-authorize plug this replaces.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can build the post-anchor redirect for either outcome.
  A failed destroy returns `{:error, %Post{}}` carrying that loaded post.

  ## Examples

      iex> destroy_post(moderator, "1")
      {:ok, %Post{}}

      iex> destroy_post(user, "1")
      {:error, :unauthorized}

      iex> destroy_post(moderator, "not-an-integer")
      {:error, :not_found}

  """
  @spec destroy_post(User.t() | nil, any()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def destroy_post(actor, post_id) do
    case IntegerId.parse(post_id) do
      {:ok, id} ->
        post =
          Post
          |> preload([:topic, topic: :forum])
          |> Repo.get(id)

        with :ok <- authorize(actor, :hide, post) do
          case destroy_post(post) do
            {:ok, destroyed_post} ->
              log_post_destroy(actor, destroyed_post)
              {:ok, destroyed_post}

            _error ->
              {:error, post}
          end
        end

      :error ->
        {:error, :not_found}
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
  Marks a post as destroyed and removes its text (hard deletion).

  This is the internal destroy engine shared with `destroy_post/2` and
  `Philomena.Users.Eraser`; it performs no authorization and writes no
  moderation log, so controller-facing callers go through `destroy_post/2`.

  ## Examples

      iex> destroy_post(post)
      {:ok, %Post{}}

  """
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
        UserStatistics.inc_stat(post.user_id, :posts_count, -1)
        reindex_post(post)

        {:ok, post}

      error ->
        error
    end
  end

  @doc """
  Approves the post named by the raw request `post_id`, on behalf of `actor`
  (a user, or `nil` for an anonymous visitor).

  Authorization (`:approve` on the loaded post) happens here; on success the
  post's associated reports are closed, the author's forum post count is
  incremented, the post is reindexed, and a moderation log is written
  attributing the approval to `actor`. An id that cannot name a row is
  `{:error, :not_found}`, while a well-formed id that names no row authorizes
  `nil` - which no rule permits - and is therefore `{:error, :unauthorized}`,
  preserving the behavior of the load-then-authorize plug this replaces.

  The post is loaded (and returned) with its `:topic` and the topic's `:forum`
  preloaded so the caller can build the post-anchor redirect for either
  outcome. A failed approval changeset returns `{:error, %Post{}}` carrying
  that loaded post.

  ## Examples

      iex> approve_post(moderator, "1")
      {:ok, %Post{}}

      iex> approve_post(user, "1")
      {:error, :unauthorized}

      iex> approve_post(moderator, "not-an-integer")
      {:error, :not_found}

  """
  @spec approve_post(User.t() | nil, any()) ::
          {:ok, Post.t()}
          | {:error, :unauthorized | :not_found}
          | {:error, Post.t()}
  def approve_post(actor, post_id) do
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

  defp approve_loaded_post(actor, %Post{} = post) do
    report_query = Reports.close_report_query({"Post", post.id}, actor)
    changeset = Post.approve_changeset(post)

    Multi.new()
    |> Multi.update(:post, changeset)
    |> Multi.update_all(:reports, report_query, [])
    |> Repo.transaction()
    |> case do
      {:ok, %{post: approved_post, reports: {_count, reports}}} ->
        UserStatistics.inc_stat(approved_post.user_id, :posts_count)
        Reports.reindex_reports(reports)
        reindex_post(approved_post)
        log_post_approval(actor, approved_post)

        {:ok, approved_post}

      _error ->
        # The approval changeset sets a boolean unconditionally, so this branch
        # is not reachable today; it carries the loaded post so a caller can
        # still redirect to the post anchor if that ever changes.
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
  Loads the edit history of the post named by the raw request `post_id` within
  the topic named by `topic_slug` in the forum named by `forum_slug`, on behalf
  of `actor` (a user, or `nil` for an anonymous visitor). This is a public read
  with no ban check.

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them
  (the retired LoadTopicPlug `show_hidden: false` chain). The post is then loaded
  by id within that topic: a missing post is `{:error, :not_found}`, and a post
  hidden from users is visible only when `actor` may `:show` it, otherwise
  `{:error, :unauthorized}` - reproducing the retired LoadPostPlug
  `show_hidden: false` chain. The post id is not integer-guarded before the query,
  matching that plug, so a non-integer id raises `Ecto.Query.CastError` exactly
  as before.

  On success the loaded post (with its topic, forum, and author associations
  preloaded for rendering) is returned alongside the topic (for the page title)
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
  @spec post_history(User.t() | nil, String.t(), String.t(), any()) ::
          {:ok, {Topic.t(), Post.t(), [Version.t()]}}
          | {:error, :unauthorized | :not_found}
  def post_history(actor, forum_slug, topic_slug, post_id) do
    with {:ok, _forum, topic} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         {:ok, post} <- load_topic_post(actor, topic, post_id) do
      {:ok, {topic, post, Versions.load_last_versions("Post", post)}}
    end
  end

  # Reproduces LoadPostPlug with the default `show_hidden: false`: the post is
  # loaded by id scoped to the topic (with the topic/forum/author preloads the
  # history page renders), a missing row is `{:error, :not_found}`, and a post
  # hidden from users is authorized for `:show` - visible to staff, otherwise
  # `{:error, :unauthorized}`.
  defp load_topic_post(actor, topic, post_id) do
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
  Returns an `%Ecto.Changeset{}` for tracking post changes.

  ## Examples

      iex> change_post(post)
      %Ecto.Changeset{source: %Post{}}

  """
  def change_post(%Post{} = post) do
    Post.changeset(post, %{})
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
