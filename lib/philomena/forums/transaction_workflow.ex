defmodule Philomena.Forums.TransactionWorkflow do
  @moduledoc """
  Composable, locking transaction steps for forum hierarchy operations.

  Besides locking and authorization, these helpers maintain the denormalized
  counters and last-post pointers used by forum and topic listings. Call them
  in the same `Multi` as the mutation, after the row-changing step and while
  the affected hierarchy rows remain locked.

  ## Counter invariants

  - `Topic.post_count` is the number of non-destroyed posts in that topic. A
    hidden post still contributes to this count.
  - `Forum.topic_count` is the number of non-hidden topics in the forum.
  - `Forum.post_count` is the sum of `post_count` for non-hidden topics in the
    forum. Consequently, hiding or restoring a topic transfers all of its
    posts; destroying a post changes the forum count only when its topic is
    visible.
  - A visible topic also contributes one to its author's `topics_count`.

  Create a topic with `put_topic_visibility_counters(visible?: true)`, and
  reverse that step when hiding it. Add `put_post_topic_visibility_counters/2`
  whenever a post becomes or ceases to be non-destroyed, and pair it with
  `put_post_forum_visibility_counters/2` for a visible topic. Move a topic
  with `put_topic_transfer_counters/1`, which transfers its visible
  contribution between the locked forums.

  ## Last-post invariants

  A topic's `last_post_id` and `last_replied_to_at` identify its newest post
  visible to users. A forum's `last_post_id` identifies the newest visible
  post in one of its non-hidden topics. Refresh the topic pointer after a
  reply or a post visibility change, and refresh the forum pointer after a
  reply, a post visibility change, a topic visibility change, or a topic move.
  Topic creation refreshes both pointers; its initial post is included by the
  topic insert. A move refreshes both the source and target forums. Hidden or
  restored posts change pointers but not counters. A post must be hidden before
  it can be destroyed, so destruction alone changes counters but not pointers;
  a combined hide-and-destroy operation refreshes them for the hide.

  The locking helpers establish the serialization boundary for these updates:
  lock the forum before its topic, and lock both forums in sorted order before
  moving a topic. Do not use a counter or refresh helper with an unlocked,
  stale parent row, or in a separate transaction from the mutation.
  """

  import Philomena.Authorization, only: [authorize: 3]
  import Ecto.Query

  alias Philomena.Attribution.Actor
  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic
  alias Philomena.Posts.Post
  alias Philomena.Users.User
  alias Philomena.UserStatistics
  alias Philomena.IntegerId

  alias Philomena.Multi

  @doc """
  Adds a row lock for the forum identified by `forum_slug` and authorizes
  `actor` for `action` on that forum.

  The lock and authorization are added to the supplied transaction as the
  `:locked_forum` and `:authorize` steps. A missing forum is reported as
  `:not_found`, and a failed authorization as `:unauthorized` by the
  transaction's normal error tuple. Use this before a mutation that changes
  forum-level counters or last-post pointers, so later cache steps read the
  locked forum row.

  ## Examples

      iex> Multi.new() |> put_forum_lock(actor, "dis", :show)
      %Multi{}

  """
  @spec put_forum_lock(
          multi :: Multi.t(),
          actor_or_user :: Actor.t() | User.t(),
          forum_slug :: String.t(),
          forum_action :: atom()
        ) :: Multi.t()
  def put_forum_lock(%Multi{} = multi, actor_or_user, forum_slug, forum_action) do
    forum_query =
      from forum in Forum,
        as: :forum,
        where: forum.short_name == ^forum_slug

    multi
    |> Multi.lock_one(:locked_forum, forum_query)
    |> Multi.run(:authorize, fn _repo, %{locked_forum: forum} ->
      with :ok <- authorize(actor_or_user, forum_action, forum) do
        {:ok, nil}
      end
    end)
  end

  @doc """
  Adds row locks and authorization for a forum and one of its topics.

  The forum is locked first, followed by the topic selected beneath that
  forum. The supplied transaction receives `:locked_forum`, `:locked_topic`,
  and `:authorize` steps. `forum_action` and `topic_action` are checked only
  after both rows have been locked.

  This is the required setup for a post or topic-visibility mutation whose
  counter or last-post steps read `:locked_forum` and `:locked_topic`.

  ## Examples

      iex> Multi.new() |> put_forum_and_topic_locks(actor, "dis", :show, "topic", :show)
      %Multi{}

  """
  @spec put_forum_and_topic_locks(
          multi :: Multi.t(),
          actor_or_user :: Actor.t() | User.t(),
          forum_slug :: String.t(),
          forum_action :: atom(),
          topic_slug :: String.t(),
          topic_action :: atom()
        ) ::
          Multi.t()
  def put_forum_and_topic_locks(
        %Multi{} = multi,
        actor_or_user,
        forum_slug,
        forum_action,
        topic_slug,
        topic_action
      ) do
    forum_query =
      from forum in Forum,
        as: :forum,
        where: forum.short_name == ^forum_slug

    topic_query =
      from topic in Topic,
        as: :topic,
        where: topic.slug == ^topic_slug,
        where:
          exists(
            from forum in forum_query,
              where: parent_as(:topic).forum_id == forum.id
          ),
        preload: :forum

    multi
    |> Multi.lock_one(:locked_forum, forum_query)
    |> Multi.lock_one(:locked_topic, topic_query)
    |> Multi.run(:authorize, fn _repo, %{locked_forum: forum, locked_topic: topic} ->
      with :ok <- authorize(actor_or_user, forum_action, forum),
           :ok <- authorize(actor_or_user, topic_action, topic) do
        {:ok, nil}
      end
    end)
  end

  @doc """
  Adds consistent row locks and authorization for a topic move.

  Both the source and target forums are locked in sorted short-name order to
  prevent concurrent moves in opposite directions from deadlocking. Duplicate
  forum names are locked once. Forums are exposed as `:locked_source_forum` and
  `:locked_target_forum`. The topic is locked beneath the source forum, and
  all three requested actions are checked in the `:authorize` step. Use this
  before `put_topic_transfer_counters/1` and both forum last-post refreshes,
  so concurrent opposite-direction moves cannot leave either forum cache
  stale.

  ## Examples

      iex> Multi.new() |> put_source_and_target_forum_and_topic_locks(actor, "dis", :show, "general", :show, "topic", :move)
      %Multi{}

  """
  @spec put_source_and_target_forum_and_topic_locks(
          multi :: Multi.t(),
          actor_or_user :: Actor.t() | User.t(),
          source_forum_slug :: String.t(),
          source_forum_action :: atom(),
          target_forum_slug :: String.t(),
          target_forum_action :: atom(),
          topic_slug :: String.t(),
          topic_action :: atom()
        ) :: Multi.t()
  def put_source_and_target_forum_and_topic_locks(
        %Multi{} = multi,
        actor_or_user,
        source_forum_slug,
        source_forum_action,
        target_forum_slug,
        target_forum_action,
        topic_slug,
        topic_action
      ) do
    topic_query =
      from topic in Topic,
        as: :topic,
        where: topic.slug == ^topic_slug,
        where:
          exists(
            from forum in Forum,
              as: :forum,
              where: forum.short_name == ^source_forum_slug,
              where: parent_as(:topic).forum_id == forum.id
          ),
        preload: [:forum]

    # Concurrent moves between the same forums need to use a consistent locking order.
    # Forums are deduplicated and ordered by short_name to achieve this.

    [source_forum_slug, target_forum_slug]
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(multi, fn short_name, multi ->
      forum_query =
        from forum in Forum,
          where: forum.short_name == ^short_name

      Multi.lock_one(multi, {:locked_forum, short_name}, forum_query)
    end)
    |> Multi.run(
      :locked_source_forum,
      fn _repo, %{{:locked_forum, ^source_forum_slug} => forum} ->
        {:ok, forum}
      end
    )
    |> Multi.run(
      :locked_target_forum,
      fn _repo, %{{:locked_forum, ^target_forum_slug} => forum} ->
        {:ok, forum}
      end
    )
    |> Multi.lock_one(:locked_topic, topic_query)
    |> Multi.run(
      :authorize,
      fn _repo,
         %{
           locked_source_forum: source_forum,
           locked_target_forum: target_forum,
           locked_topic: topic
         } ->
        with :ok <- authorize(actor_or_user, source_forum_action, source_forum),
             :ok <- authorize(actor_or_user, target_forum_action, target_forum),
             :ok <- authorize(actor_or_user, topic_action, topic) do
          {:ok, nil}
        end
      end
    )
  end

  @doc """
  Adds row locks and authorization for a post-scoped topic operation.

  The forum, topic, and post are selected using all supplied route members and
  are locked in that order. The transaction receives `:locked_forum`,
  `:locked_topic`, `:locked_post`, and `:authorize` steps; the forum, topic,
  and post actions are checked after the locks are acquired.

  This is the required setup for a post hide, restore, or destruction followed
  by its affected counter and last-post cache steps.

  ## Examples

      iex> Multi.new() |> put_forum_and_topic_and_post_locks(actor, "dis", :show, "topic", :show, 1, :hide)
      %Multi{}

  """
  @spec put_forum_and_topic_and_post_locks(
          multi :: Multi.t(),
          actor_or_user :: Actor.t() | User.t(),
          forum_slug :: String.t(),
          forum_action :: atom(),
          topic_slug :: String.t(),
          topic_action :: atom(),
          post_id :: IntegerId.integer_id(),
          post_action :: atom()
        ) :: Multi.t()
  def put_forum_and_topic_and_post_locks(
        %Multi{} = multi,
        actor_or_user,
        forum_slug,
        forum_action,
        topic_slug,
        topic_action,
        post_id,
        post_action
      ) do
    forum_query =
      from forum in Forum,
        as: :forum,
        where: forum.short_name == ^forum_slug

    topic_query =
      from topic in Topic,
        as: :topic,
        where: topic.slug == ^topic_slug,
        where:
          exists(
            from forum in forum_query,
              where: parent_as(:topic).forum_id == forum.id
          )

    # TODO: user preload only needed for approvals
    post_query =
      from post in Post,
        as: :post,
        where: post.id == ^post_id,
        where:
          exists(
            from topic in topic_query,
              where: parent_as(:post).topic_id == topic.id
          ),
        preload: [:user, topic: :forum]

    multi
    |> Multi.lock_one(:locked_forum, forum_query)
    |> Multi.lock_one(:locked_topic, topic_query)
    |> Multi.lock_one(:locked_post, post_query)
    |> Multi.run(:authorize, fn
      _repo, %{locked_forum: forum, locked_topic: topic, locked_post: post} ->
        with :ok <- authorize(actor_or_user, forum_action, forum),
             :ok <- authorize(actor_or_user, topic_action, topic),
             :ok <- authorize(actor_or_user, post_action, post) do
          {:ok, nil}
        end
    end)
  end

  @doc """
  Converts a transaction error from a locking workflow to its public error.

  Authorization and missing-row errors are reduced to `{:error,
  :unauthorized}` and `{:error, :not_found}`, respectively. Other transaction
  results are intentionally not handled by this helper. Use it only after
  `Multi.transact/1` on a workflow that installed one of this module's locking
  helpers; it does not translate cache-update or changeset failures.

  ## Examples

      iex> map_lock_errors({:error, :authorize, :unauthorized, %{}})
      {:error, :unauthorized}

  """
  @spec map_lock_errors(Multi.failure()) :: {:error, :not_found | :unauthorized}
  def map_lock_errors(result) do
    case result do
      {:error, _step, :unauthorized, _changes} ->
        {:error, :unauthorized}

      {:error, _step, :not_found, _changes} ->
        {:error, :not_found}
    end
  end

  @doc """
  Adds an update step that recalculates a forum's cached last visible post.

  Maintains `Forum.last_post_id` as the highest-ID post that is visible and
  belongs to a non-hidden topic in that forum. The step reads the locked forum
  from `forum_step`, which defaults to `:locked_forum`. Add it after a reply,
  post visibility change, topic visibility change, or topic move; a move must
  refresh both locked forums.

  ## Examples

      iex> (Multi.new()
      ...> |> put_forum_and_topic_locks(actor, "dis", :show, "topic", :hide)
      ...> |> Multi.update(:topic, topic_changeset)
      ...> |> put_refresh_forum_last_post())
      %Multi{}

  """
  @spec put_refresh_forum_last_post(Multi.t(), Multi.name()) :: Multi.t()
  def put_refresh_forum_last_post(%Multi{} = multi, forum_step \\ :locked_forum) do
    Multi.update_all(
      multi,
      {:refresh_forum_last_post, forum_step},
      fn %{^forum_step => forum} ->
        update_forum_last_post_query(forum.id)
      end,
      []
    )
  end

  @doc """
  Adds an update step that recalculates a topic's cached last visible post.

  Maintains `Topic.last_post_id` and `Topic.last_replied_to_at` from the
  newest post visible to users in that topic. The step reads the locked topic
  from `topic_step`, which defaults to `:locked_topic`. Add it after inserting,
  hiding, or restoring a post, and after hiding or restoring a topic. For topic
  creation, pass `:topic` because the inserted topic is the row whose initial
  post must be considered. A destruction-only operation does not need this
  step because posts must already be hidden before they can be destroyed.

  ## Examples

      iex> (Multi.new()
      ...> |> put_forum_and_topic_locks(actor, "dis", :show, "topic", :create_post)
      ...> |> Multi.insert(:post, post_changeset)
      ...> |> put_refresh_topic_last_post())
      %Multi{}

  """
  @spec put_refresh_topic_last_post(Multi.t(), Multi.name()) :: Multi.t()
  def put_refresh_topic_last_post(%Multi{} = multi, topic_step \\ :locked_topic) do
    Multi.update_all(
      multi,
      {:refresh_topic_last_post, topic_step},
      fn %{^topic_step => topic} ->
        update_topic_last_post_query(topic.id)
      end,
      []
    )
  end

  @doc """
  Adds counter updates for a topic becoming visible or hidden.

  Maintains `Forum.topic_count`, `Forum.post_count`, and the topic author's
  `topics_count`. `visible?: true` adds one topic and that topic's complete
  non-destroyed `post_count`; `false` removes the same contribution. The
  transaction must contain `:locked_forum` and the updated `:topic`, and must
  call this immediately after changing `Topic.hidden_from_users`.

  ## Examples

      iex> (Multi.new()
      ...> |> put_forum_and_topic_locks(actor, "dis", :show, "topic", :unhide)
      ...> |> Multi.update(:topic, topic_changeset)
      ...> |> put_topic_visibility_counters(visible?: true))
      %Multi{}

  """
  @spec put_topic_visibility_counters(Multi.t(), [{:visible?, boolean()}]) :: Multi.t()
  def put_topic_visibility_counters(%Multi{} = multi, [{:visible?, visible?}]) do
    scale = if visible?, do: 1, else: -1

    multi
    |> UserStatistics.put_increment(fn %{topic: topic} -> topic.user_id end, :topics_count, scale)
    |> Multi.update_all(
      :forum_post_count,
      fn %{locked_forum: forum, topic: topic} ->
        Forum
        |> where(id: ^forum.id)
        |> update(inc: [post_count: ^(scale * topic.post_count), topic_count: ^scale])
      end,
      []
    )
  end

  @doc """
  Adds forum counter updates for a topic transfer.

  Maintains `Forum.topic_count` and `Forum.post_count` for both forums. The
  updated topic is read from `:topic`. When it is visible, its one-topic and
  complete `post_count` contribution is moved from `:locked_source_forum` to
  `:locked_target_forum`. A hidden topic contributes to neither forum, so no
  counters change. Call this immediately after moving the topic and before
  refreshing the last-post pointers of both locked forums.

  ## Examples

      iex> (Multi.new()
      ...> |> put_source_and_target_forum_and_topic_locks(actor, "dis", :show, "gen", :show, "topic", :move)
      ...> |> Multi.update(:topic, topic_changeset)
      ...> |> put_topic_transfer_counters())
      %Multi{}

  """
  @spec put_topic_transfer_counters(Multi.t()) :: Multi.t()
  def put_topic_transfer_counters(%Multi{} = multi) do
    Multi.merge(multi, fn
      %{topic: %{hidden_from_users: true}} ->
        # Hidden topics do not contribute to forum post count.
        Multi.new()

      %{locked_source_forum: source_forum, locked_target_forum: target_forum, topic: topic} ->
        source_forum_query =
          Forum
          |> where(id: ^source_forum.id)
          |> update(inc: [post_count: ^(-topic.post_count), topic_count: -1])

        target_forum_query =
          Forum
          |> where(id: ^target_forum.id)
          |> update(inc: [post_count: ^topic.post_count, topic_count: 1])

        Multi.new()
        |> Multi.update_all(:source_forum_count, source_forum_query, [])
        |> Multi.update_all(:target_forum_count, target_forum_query, [])
    end)
  end

  @doc """
  Adds a forum post-counter update for a post becoming or ceasing to be
  non-destroyed.

  Maintains `Forum.post_count`. `visible?: true` increments it and `false`
  decrements it, but only when `:locked_topic` is visible. Hidden topics do not
  contribute posts to their forum. The transaction must contain
  `:locked_forum` and `:locked_topic`, and call this after the post mutation.
  Pair it with `put_post_topic_visibility_counters/2` whenever the post's
  non-destroyed state changes.

  ## Examples

      iex> (Multi.new()
      ...> |> put_forum_and_topic_and_post_locks(actor, "dis", :show, "topic", :show, 1, :delete)
      ...> |> Multi.update(:post, post_changeset)
      ...> |> put_post_topic_visibility_counters(visible?: false)
      ...> |> put_post_forum_visibility_counters(visible?: false))
      %Multi{}

  """
  @spec put_post_forum_visibility_counters(Multi.t(), [{:visible?, boolean()}]) :: Multi.t()
  def put_post_forum_visibility_counters(%Multi{} = multi, [{:visible?, visible?}]) do
    Multi.merge(multi, fn
      %{locked_topic: %{hidden_from_users: true}} ->
        # Hidden topics do not contribute to forum post count.
        Multi.new()

      %{locked_forum: forum} ->
        scale = if visible?, do: 1, else: -1

        forum_query =
          Forum
          |> where(id: ^forum.id)
          |> update(inc: [post_count: ^scale])

        Multi.update_all(Multi.new(), :forum_post_count, forum_query, [])
    end)
  end

  @doc """
  Adds a topic post-counter update for a post becoming or ceasing to be
  non-destroyed.

  Maintains `Topic.post_count`, which includes every non-destroyed post,
  whether or not it is hidden from users. `visible?: true` increments the
  counter and `false` decrements it. The topic is read from `:locked_topic`;
  call this after the post mutation and pair it with
  `put_post_forum_visibility_counters/2` when the topic is visible.

  ## Examples

      iex> Multi.new()
      ...> |> put_forum_and_topic_locks(actor, "dis", :show, "topic", :create_post)
      ...> |> Multi.insert(:post, post_changeset)
      ...> |> put_post_topic_visibility_counters(visible?: true)
      %Multi{}

  """
  @spec put_post_topic_visibility_counters(Multi.t(), [{:visible?, boolean()}]) :: Multi.t()
  def put_post_topic_visibility_counters(%Multi{} = multi, [{:visible?, visible?}]) do
    scale = if visible?, do: 1, else: -1

    # Topic post counts record all non-destroyed posts.
    Multi.update_all(
      multi,
      :topic_post_count,
      fn %{locked_topic: topic} ->
        Topic
        |> where(id: ^topic.id)
        |> update(inc: [post_count: ^scale])
      end,
      []
    )
  end

  @doc """
  Adds a query step that finds the highest post position in the locked topic.

  The result is stored under `:max_topic_position` and is `nil` when the topic
  has no posts. Use it after locking the topic and before inserting a reply,
  so the new post's `topic_position` follows the current maximum without
  concurrent replies sharing a position.

  ## Examples

      iex> (Multi.new()
      ...> |> put_forum_and_topic_locks(actor, "dis", :show, "topic", :create_post)
      ...> |> put_max_topic_position())
      %Multi{}

  """
  @spec put_max_topic_position(Multi.t()) :: Multi.t()
  def put_max_topic_position(%Multi{} = multi) do
    Multi.one(multi, :max_topic_position, fn %{locked_topic: topic} ->
      Post
      |> where(topic_id: ^topic.id)
      |> order_by(desc: :topic_position)
      |> select([p], p.topic_position)
      |> limit(1)
    end)
  end

  defp update_forum_last_post_query(forum_id) do
    Forum
    |> where(id: ^forum_id)
    |> update(
      set: [
        last_post_id:
          fragment(
            "SELECT max(posts.id) FROM posts JOIN topics ON posts.topic_id = topics.id WHERE topics.forum_id = ? AND topics.hidden_from_users IS FALSE AND posts.hidden_from_users IS FALSE",
            ^forum_id
          )
      ]
    )
  end

  defp update_topic_last_post_query(topic_id) do
    Topic
    |> where(id: ^topic_id)
    |> update(
      set: [
        last_post_id:
          fragment(
            "SELECT max(id) FROM posts WHERE topic_id = ? AND hidden_from_users IS FALSE",
            ^topic_id
          ),
        last_replied_to_at:
          fragment(
            "SELECT max(created_at) FROM posts where topic_id = ? AND hidden_from_users IS FALSE",
            ^topic_id
          )
      ]
    )
  end
end
