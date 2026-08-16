defmodule Philomena.Posts do
  @moduledoc """
  Forum post reads, writes, moderation, and search indexing.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Multi
  alias Philomena.Repo

  alias PhilomenaQuery.Search
  alias Philomena.Topics.{ForumTopic, Topic}
  alias Philomena.Topics
  alias Philomena.Forums
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.UserStatistics
  alias Philomena.Users.User
  alias Philomena.Posts.{Post, PostVersion}
  alias Philomena.Posts
  alias Philomena.IndexWorker
  alias Philomena.Forums.{Forum, Visibility}
  alias Philomena.Notifications
  alias Philomena.Reports
  alias Philomena.Versions
  alias Philomena.RateLimiter
  alias Philomena.Attribution.Actor

  @post_create_window 15

  defp persist_post(%Topic{} = topic, %Actor{user: user} = actor, params) do
    now = DateTime.utc_now(:second)

    topic_query =
      Topic
      |> where(id: ^topic.id)

    forum_query =
      Forum
      |> where(id: ^topic.forum_id)

    Multi.new()
    |> Multi.lock_one(:topic, topic_query)
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
    |> Multi.transact()
    |> case do
      {:ok, %{post: post}} = result ->
        reindex_post(post)

        result

      error ->
        error
    end
  end

  defp persist_post_update(%Post{} = post, %Actor{} = actor, attrs) do
    now = DateTime.utc_now(:second)

    post_query =
      Post
      |> where(id: ^post.id)
      |> preload(topic: :forum, user: [awards: :badge])
      |> lock("FOR UPDATE")

    Multi.new()
    |> Multi.one(:original_post, post_query)
    |> Multi.update(:post, fn %{original_post: original_post} ->
      Post.changeset(original_post, attrs, now)
    end)
    |> Versions.record_edit(:version, :original_post, :post, actor)
    |> put_reindex_post(:post)
    |> Multi.transact()
    |> case do
      {:ok, _changes} = result ->
        result

      error ->
        error
    end
  end

  defp put_reindex_post(%Multi{} = multi, step) do
    Multi.on_commit(multi, fn %{^step => post} -> reindex_post(post) end)
  end

  defp hide_loaded_post(%Post{} = post, attrs, %User{} = user) do
    post = post |> Repo.preload(:topic)

    Multi.new()
    |> Multi.update(:post, Post.hide_changeset(post, attrs, user))
    |> Reports.put_close_reports(:reports, user, post_id: post.id)
    |> Multi.update_all(:topic, Topics.update_topic_last_post_query(post.topic_id), [])
    |> Multi.update_all(:forum, Forums.update_forum_last_post_query(post.topic.forum_id), [])
    |> put_reindex_post(:post)
    |> Multi.transact()
    |> case do
      {:ok, %{post: post}} ->
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
    |> put_reindex_post(:post)
    |> Multi.transact()
    |> case do
      {:ok, %{post: post}} ->
        {:ok, post}

      error ->
        error
    end
  end

  defp destroy_loaded_post(%Post{} = post) do
    post = post |> Repo.preload([:topic, :user])

    # TODO: bad. need to lock here.
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
    |> put_reindex_post(:post)
    |> Multi.transact()
    |> case do
      {:ok, %{post: post}} ->
        UserStatistics.increment(post.user_id, :posts_count, -1)

        {:ok, post}

      error ->
        error
    end
  end

  defp notify_post(_repo, %{post: post, topic: topic}) do
    Notifications.broadcast_forum_post(post.user, topic, post)
  end

  defp broadcast_post_creation(%{forum: %{access_level: "normal"}} = result) do
    PhilomenaWeb.Endpoint.broadcast!(
      "firehose",
      "post:create",
      PhilomenaWeb.Api.Json.Forum.Topic.PostView.render("firehose.json", result)
    )

    result
  end

  defp broadcast_post_creation(result), do: result

  defp record_post_creation(%Actor{user: user}, %Post{approved: true}),
    do: UserStatistics.increment(user, :posts_count)

  defp record_post_creation(_actor, post), do: report_non_approved(post)

  defp load_editable_post(%Actor{} = actor, forum_slug, topic_slug, post_id, action) do
    with {:ok, %ForumTopic{topic: topic}} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug),
         :ok <- authorize(actor, :create_post, topic) do
      load_post_in_topic(actor, topic, post_id, action)
    end
  end

  defp load_moderated_post(%Actor{} = actor, forum_slug, topic_slug, post_id, action) do
    with {:ok, %ForumTopic{topic: topic}} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug) do
      load_post_in_topic(actor, topic, post_id, action)
    end
  end

  defp approve_loaded_post(%Actor{user: user}, %Post{} = post) do
    changeset = Post.approve_changeset(post)

    Multi.new()
    |> Multi.update(:post, changeset)
    |> Reports.put_close_reports(:reports, user, post_id: post.id)
    |> put_reindex_post(:post)
    |> Multi.transact()
    |> case do
      {:ok, %{post: post}} ->
        UserStatistics.increment(post.user_id, :posts_count)

        {:ok, post}

      _error ->
        {:error, post}
    end
  end

  defp load_post_in_topic(%Actor{} = actor, topic, post_id, action, opts \\ []) do
    case IntegerId.parse(post_id) do
      {:ok, post_id} ->
        Post
        |> where(topic_id: ^topic.id, id: ^post_id)
        |> maybe_exclude_destroyed(Keyword.get(opts, :exclude_destroyed, false))
        |> preload(topic: :forum, user: [awards: :badge])
        |> Loader.one_and_authorize(actor, action)

      :error ->
        {:error, :not_found}
    end
  end

  defp maybe_exclude_destroyed(query, true), do: where(query, destroyed_content: false)
  defp maybe_exclude_destroyed(query, false), do: query

  defp load_reportable_post(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with {:ok, %ForumTopic{topic: topic}} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug),
         {:ok, post} <- load_post_in_topic(actor, topic, post_id, :show) do
      {:ok, {post.topic, post}}
    end
  end

  defp normalize_multi_error({:error, _name, %Ecto.Changeset{} = changeset, _changes}),
    do: {:error, changeset}

  defp normalize_multi_error(result), do: result

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking post changes.

  ## Examples

      iex> change_post(post)
      %Ecto.Changeset{source: %Post{}}

  """
  @spec change_post(Post.t()) :: Ecto.Changeset.t()
  def change_post(%Post{} = post) do
    Post.changeset(post, %{})
  end

  @doc """
  Loads one post visible to `actor` beneath its route forum and topic.

  The locator is safely parsed, and the post query is constrained by the loaded
  topic before authorization. Destroyed posts are not-found. Existing route
  members forbidden to the actor are unauthorized.

  ## Examples

      iex> load_topic_post(actor, "dis", "some-topic", "1")
      {:ok, %Post{}}

      iex> load_topic_post(actor, "dis", "some-topic", "not-a-number")
      {:error, :not_found}

  """
  @spec load_topic_post(
          Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          post_id :: Loader.integer_id()
        ) ::
          {:ok, Post.t()} | {:error, :not_found | :unauthorized}
  def load_topic_post(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with {:ok, %ForumTopic{topic: topic}} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug) do
      load_post_in_topic(actor, topic, post_id, :show, exclude_destroyed: true)
    end
  end

  @doc """
  Loads one post visible to `actor` by its global ID.

  The ID is safely parsed, the parent topic and forum are preloaded, and the
  forum, topic, and post are authorized in hierarchy order. Destroyed,
  malformed, or missing posts are not-found.

  ## Examples

      iex> load_post(actor, "1")
      {:ok, %Post{}}

      iex> load_post(actor, "999999999")
      {:error, :not_found}

  """
  @spec load_post(Actor.t(), Loader.integer_id()) ::
          {:ok, Post.t()} | {:error, :not_found | :unauthorized}
  def load_post(%Actor{} = actor, post_id) do
    with {:ok, post_id} <- IntegerId.parse(post_id),
         {:ok, post} <-
           Post
           |> where([post], post.id == ^post_id and post.destroyed_content == false)
           |> preload([:user, topic: :forum])
           |> Loader.one(),
         :ok <- authorize(actor, :show, post.topic.forum),
         :ok <- authorize(actor, :show, post.topic),
         :ok <- authorize(actor, :show, post) do
      {:ok, post}
    else
      :error -> {:error, :not_found}
      error -> error
    end
  end

  @doc """
  Searches posts visible to `actor`, applying the compiled query string and
  pagination and sorting newest first.

  Moderators and administrators search every forum and visibility state.
  Assistants search normal and assistant forums. Other actors search visible
  posts in normal forums. Results carry the associations needed by both HTML
  and JSON renderers. An empty query compiles to an empty result.

  Returns `{:ok, results}`, or `{:error, msg}` when `query_string` fails to
  compile.

  ## Examples

      iex> search_posts(actor, "chartreuse", pagination)
      {:ok, %Scrivener.Page{}}

      iex> search_posts(actor, ")", pagination)
      {:error, "Imbalanced parentheses."}

  """
  @spec search_posts(Actor.t(), String.t() | nil, Search.pagination_params()) ::
          {:ok, Scrivener.Page.t()} | {:error, String.t()}
  def search_posts(%Actor{user: user} = actor, query_string, pagination) do
    case Posts.Query.compile(query_string, user: user) do
      {:ok, query} ->
        results =
          Post
          |> Search.search_definition(
            %{
              query: %{
                bool: %{
                  must: query,
                  filter: Visibility.search_filters(actor)
                }
              },
              sort: %{created_at: :desc}
            },
            pagination
          )
          |> Search.search_records(
            preload(Post, [:deleted_by, topic: :forum, user: [awards: :badge]])
          )

        {:ok, results}

      {:error, msg} ->
        {:error, msg}
    end
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
         {:ok, %ForumTopic{forum: forum, topic: topic}} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug),
         :ok <- authorize(actor, :create_post, topic) do
      case persist_post(topic, actor, post_params || %{}) do
        {:ok, %{post: post}} ->
          RateLimiter.record_action(actor, :post_create, @post_create_window)
          record_post_creation(actor, post)
          # The firehose representation includes the topic author.
          result = %{post: post, topic: Repo.preload(topic, :user), forum: forum}

          {:ok, broadcast_post_creation(result)}

        _error ->
          {:error, forum, topic}
      end
    end
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
  @spec report_non_approved(Post.t()) :: false | {:ok, Philomena.Reports.Report.t()}
  def report_non_approved(%Post{approved: true}), do: false

  def report_non_approved(post) do
    Reports.create_system_report(
      "Approval",
      "Post contains external links",
      post_id: post.id
    )
  end

  @doc """
  Hides and destroys one loaded post for permanent user erasure.

  This function owns the post counters, report cleanup, and indexing required
  by `Philomena.Users.Eraser`. It is not a request authorization boundary;
  the erasure workflow has already selected both the post and the staff user
  responsible for the wipe.

  ## Examples

      iex> erase_post(post, moderator)
      {:ok, %Post{destroyed_content: true}}

  """
  @spec erase_post(Post.t(), User.t()) :: {:ok, Post.t()} | {:error, term()}
  def erase_post(%Post{} = post, %User{} = moderator) do
    with {:ok, hidden_post} <-
           hide_loaded_post(post, %{deletion_reason: "Site abuse"}, moderator) do
      destroy_loaded_post(hidden_post)
    end
  end

  @doc """
  Loads the post named by `post_id` within the topic named by
  `topic_slug` in the forum named by `forum_slug` for editing, on behalf of
  `actor`.

  The same full write-access check used by update runs first. The forum, topic,
  and post are then parent-scoped and authorized for `:edit`.

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
         {:ok, post} <- load_editable_post(actor, forum_slug, topic_slug, post_id, :edit) do
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
         {:ok, post} <- load_editable_post(actor, forum_slug, topic_slug, post_id, :update) do
      case persist_post_update(post, actor, post_params || %{}) do
        {:ok, %{post: updated_post}} ->
          report_non_approved(updated_post)
          {:ok, updated_post}

        {:error, :post, changeset, _changes} ->
          {:error, {post, changeset}}
      end
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

      iex> hide_post(moderator_actor, "dis", "some-topic", "1", %{"deletion_reason" => "Spam"})
      {:ok, %Post{}}

      iex> hide_post(moderator_actor, "dis", "some-topic", "1", %{"deletion_reason" => ""})
      {:error, %Post{}}

      iex> hide_post(user_actor, "dis", "some-topic", "1", %{"deletion_reason" => "Spam"})
      {:error, :unauthorized}

  """
  @spec hide_post(Actor.t(), String.t(), String.t(), Loader.integer_id(), map()) ::
          {:ok, Post.t()}
          | {:error, :ban | :unauthorized | :not_found}
          | {:error, Post.t()}
  def hide_post(%Actor{user: user} = actor, forum_slug, topic_slug, post_id, post_params) do
    with :ok <- verify_write_access(actor),
         {:ok, post} <-
           load_moderated_post(actor, forum_slug, topic_slug, post_id, :hide) do
      case hide_loaded_post(post, post_params, user) do
        {:ok, %Post{topic: topic} = post} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Post.Hide:create",
            Paths.forum_post_path(post),
            "Deleted forum post ##{post.id} in topic '#{topic.title}' (#{post.deletion_reason})"
          )

          {:ok, post}

        _error ->
          {:error, post}
      end
    end
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

      iex> unhide_post(moderator_actor, "dis", "some-topic", "1")
      {:ok, %Post{}}

      iex> unhide_post(user_actor, "dis", "some-topic", "1")
      {:error, :unauthorized}

  """
  @spec unhide_post(Actor.t(), String.t(), String.t(), Loader.integer_id()) ::
          {:ok, Post.t()}
          | {:error, :ban | :unauthorized | :not_found}
          | {:error, Post.t()}
  def unhide_post(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with :ok <- verify_write_access(actor),
         {:ok, post} <-
           load_moderated_post(actor, forum_slug, topic_slug, post_id, :unhide) do
      case unhide_post(post) do
        {:ok, %Post{topic: topic} = post} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Post.Hide:delete",
            Paths.forum_post_path(post),
            "Restored forum post ##{post.id} in topic '#{topic.title}'"
          )

          {:ok, post}

        _error ->
          {:error, post}
      end
    end
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

      iex> destroy_post(moderator_actor, "dis", "some-topic", "1")
      {:ok, %Post{}}

      iex> destroy_post(user_actor, "dis", "some-topic", "1")
      {:error, :unauthorized}

      iex> destroy_post(moderator_actor, "dis", "some-topic", "not-an-integer")
      {:error, :not_found}

  """
  @spec destroy_post(Actor.t(), String.t(), String.t(), Loader.integer_id()) ::
          {:ok, Post.t()}
          | {:error, :ban | :unauthorized | :not_found}
          | {:error, Post.t()}
  def destroy_post(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with :ok <- verify_write_access(actor),
         {:ok, post} <-
           load_moderated_post(actor, forum_slug, topic_slug, post_id, :delete) do
      case destroy_loaded_post(post) do
        {:ok, %Post{topic: topic} = post} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Post.Delete:create",
            Paths.forum_post_path(post),
            "Destroyed forum post ##{post.id} in topic '#{topic.title}'"
          )

          {:ok, post}

        _error ->
          {:error, post}
      end
    end
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

      iex> approve_post(moderator_actor, "dis", "some-topic", "1")
      {:ok, %Post{}}

      iex> approve_post(user_actor, "dis", "some-topic", "1")
      {:error, :unauthorized}

      iex> approve_post(moderator_actor, "dis", "some-topic", "not-an-integer")
      {:error, :not_found}

  """
  @spec approve_post(Actor.t(), String.t(), String.t(), Loader.integer_id()) ::
          {:ok, Post.t()}
          | {:error, :ban | :unauthorized | :not_found}
          | {:error, Post.t()}
  def approve_post(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with :ok <- verify_write_access(actor),
         {:ok, post} <-
           load_moderated_post(actor, forum_slug, topic_slug, post_id, :approve) do
      case approve_loaded_post(actor, post) do
        {:ok, post} ->
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Post.Approve:create",
            Paths.forum_post_path(post),
            "Approved forum post ##{post.id} in topic '#{post.topic.title}'"
          )

          {:ok, post}

        _error ->
          {:error, post}
      end
    end
  end

  @doc """
  Loads the edit history of the post named by `post_id` within
  the topic named by `topic_slug` in the forum named by `forum_slug`, on behalf
  of `actor`.

  The forum is loaded by short name and authorized for `:show`, and the topic is
  loaded by slug with hidden topics visible only to actors who may `:show` them.
  The post is then loaded by id within that topic: malformed, missing, and
  wrong-topic IDs return `{:error, :not_found}`. A post hidden from users is
  visible only when `actor` may `:show` it, otherwise
  `{:error, :unauthorized}`.

  On success the loaded post (with its topic, forum, and author associations
  preloaded) is returned alongside the topic and the last 25 versions of the
  post, newest first, with diffs and version authors resolved.

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
    with {:ok, %ForumTopic{topic: topic}} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug),
         {:ok, post} <- load_post_in_topic(actor, topic, post_id, :show) do
      {:ok, {topic, post, Versions.for_post(post)}}
    end
  end

  @doc """
  Loads a post as a report target within its route forum and topic.

  The forum and topic visibility checks run before the post is loaded through a
  parent-scoped query. Malformed, missing, and mismatched post IDs are always
  not-found. The Reports context owns write access and form construction.

  ## Examples

      iex> load_report_target(actor, "dis", "some-topic", "1")
      {:ok, %Post{}}
  """
  @spec load_report_target(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          Loader.integer_id()
        ) ::
          {:ok, Post.t()} | {:error, :unauthorized | :not_found}
  def load_report_target(%Actor{} = actor, forum_slug, topic_slug, post_id) do
    with {:ok, {_topic, post}} <-
           load_reportable_post(actor, forum_slug, topic_slug, post_id) do
      {:ok, post}
    end
  end

  @doc """
  Updates post search indices when a user's name changes.

  ## Examples

      iex> user_name_reindex("old_username", "new_username")
      :ok

  """
  @spec user_name_reindex(String.t(), String.t()) :: term()
  def user_name_reindex(old_name, new_name) do
    data = Posts.SearchIndex.user_name_update_by_query(old_name, new_name)

    Search.update_by_query(Post, data.query, data.set_replacements, data.replacements)
  end

  @doc """
  Queues a single post for search index updates.
  Returns the post struct unchanged, for use in a pipeline.

  ## Examples

      iex> reindex_post(post)
      %Post{}

  """
  @spec reindex_post(Post.t()) :: Post.t()
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
  @spec reindex_posts_in_topic(Topic.t()) :: :ok
  def reindex_posts_in_topic(%Topic{} = topic) do
    Exq.enqueue(Exq, "indexing", IndexWorker, ["Posts", "topic_id", [topic.id]])

    :ok
  end

  @doc """
  Provides preload queries for post indexing operations.

  ## Examples

      iex> indexing_preloads()
      [user: user_query, topic: topic_query]

  """
  @spec indexing_preloads() :: list()
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
  @spec perform_reindex(atom(), [term()]) :: term()
  def perform_reindex(column, condition) do
    Post
    |> preload(^indexing_preloads())
    |> where([p], field(p, ^column) in ^condition)
    |> Search.reindex(Post)
  end
end
