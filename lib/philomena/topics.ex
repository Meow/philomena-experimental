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
  alias Philomena.ModerationLogs
  alias Philomena.ModerationLogs.Paths
  alias Philomena.IntegerId
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

  @doc """
  Loads the forum named by `forum_slug` and, within it, the topic named by
  `topic_slug`, on behalf of `actor` (the acting user).

  Reproduces the retired plug chain shared by every forum/topic navigation
  route: the forum was loaded by short name and authorized for `:show` (an
  unknown forum authorizes `nil`, which no ordinary rule permits, so it is
  `{:error, :unauthorized}`), then the topic was loaded by slug within that
  forum. `show_hidden` is the LoadTopicPlug option that diverges callers on
  hidden topics: with `show_hidden: false` (the default) a hidden topic is
  visible only when the actor may `:show` it, otherwise `{:error, :unauthorized}`;
  with `show_hidden: true` a hidden topic always comes back.

  Returns `{:ok, forum, topic}`, `{:error, :unauthorized}` when the forum or the
  topic is not visible to the actor, or `{:error, :not_found}` when the forum
  exists but the topic does not.

  This is the loader that `Philomena.Polls` reuses so poll editing shares the
  exact forum/topic visibility semantics of the topic routes.

  ## Examples

      iex> load_forum_topic(moderator, "dis", "some-topic", show_hidden: false)
      {:ok, %Forum{}, %Topic{}}

  """
  @spec load_forum_topic(User.t() | nil, String.t(), String.t(), keyword()) ::
          {:ok, Forum.t(), Topic.t()} | {:error, :unauthorized | :not_found}
  def load_forum_topic(actor, forum_slug, topic_slug, opts) do
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
  Clears `actor`'s unread notifications for the topic named by `topic_slug`
  within the forum named by `forum_slug`.

  Unlike the subscription API, this reproduces a plain `load_resource` chain
  with no authorization: the forum was loaded by short name with `required:
  true`, so an unknown short name is `{:error, :not_found}` (the not-found
  handler, not the unauthorized path), and the topic was loaded with
  `show_hidden: true` and no `:show` check. There is deliberately no forum or
  topic visibility authorization here - a user can mark topics read in a forum
  they cannot see, and hidden topics can be marked read, exactly as the retired
  plug chain allowed.

  Returns `{:ok, topic}` after clearing the notifications, or
  `{:error, :not_found}` when the forum or the topic does not exist.

  ## Examples

      iex> mark_topic_read(user, "dis", "some-topic")
      {:ok, %Topic{}}

      iex> mark_topic_read(user, "dis", "nonexistent")
      {:error, :not_found}

  """
  @spec mark_topic_read(User.t() | nil, String.t(), String.t()) ::
          {:ok, Topic.t()} | {:error, :not_found}
  def mark_topic_read(actor, forum_slug, topic_slug) do
    with {:ok, topic} <- load_forum_topic_for_read(actor, forum_slug, topic_slug) do
      clear_topic_notification(topic, actor)
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
  Sticks the topic named by `topic_slug` within the forum named by
  `forum_slug`, on behalf of `actor` (the acting user).

  The forum is loaded by short name and authorized for `:show`, the topic is
  loaded by slug (a hidden topic stays invisible unless the actor may `:show`
  it, exactly as the retired LoadTopicPlug `show_hidden: false` chain behaved),
  and the `:hide` permission on the topic is then checked. On success a
  moderation log is written attributing the stick to the actor.

  Returns `{:ok, {forum, topic}}` on success (both are needed to redirect back
  to the topic), `{:error, forum, topic}` when the stick changeset is rejected
  (unreachable in practice, since the changeset has no validation, but kept so
  the controller can still redirect back to the topic), `{:error, :unauthorized}`
  when the actor may not see the forum/topic or stick the topic, or
  `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> stick_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec stick_topic(User.t() | nil, String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def stick_topic(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case stick_topic(topic) do
        {:ok, stuck_topic} ->
          # Body reads the title off the post-update topic; forum name off the
          # separately loaded forum. Byte-for-byte the retired `log_details/2`.
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
  authorization and writes no moderation log, so controller-facing callers go
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
  unstick is rejected (so the controller can redirect back to the topic),
  `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unstick_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unstick_topic(User.t() | nil, String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def unstick_topic(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case unstick_topic(topic) do
        {:ok, unstuck_topic} ->
          # Body reads the title off the post-unstick topic; forum name off the
          # separately loaded forum. Byte-for-byte the retired `log_details/2`.
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
  authorization and writes no moderation log, so controller-facing callers go
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
  it, exactly as the retired LoadTopicPlug `show_hidden: false` chain behaved),
  and the `:hide` permission on the topic is then checked. On success a
  moderation log is written attributing the lock to the actor.

  Returns `{:ok, {forum, topic}}` on success (both are needed to redirect back
  to the topic), `{:error, forum, topic}` when the lock changeset is rejected
  (e.g. a blank reason, so the controller can still redirect back to the
  topic), `{:error, :unauthorized}` when the actor may not see the forum/topic
  or lock the topic, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> lock_topic(moderator, "dis", "some-topic", %{"lock_reason" => "Off topic"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> lock_topic(moderator, "dis", "some-topic", %{"lock_reason" => ""})
      {:error, %Forum{}, %Topic{}}

  """
  @spec lock_topic(User.t() | nil, String.t(), String.t(), map()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def lock_topic(actor, forum_slug, topic_slug, topic_params) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case lock_topic(topic, topic_params, actor) do
        {:ok, locked_topic} ->
          # The body reads the reason and title off the post-update topic, and
          # the forum name off the separately loaded forum (the loaded topic
          # carries no preloaded `:forum`). This reproduces the retired
          # `log_details/2` string byte-for-byte.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Lock:create",
            Paths.topic_path(forum, locked_topic),
            "Locked topic '#{locked_topic.title}' (#{locked_topic.lock_reason}) in #{forum.name}"
          )

          {:ok, {forum, locked_topic}}

        {:error, %Ecto.Changeset{}} ->
          # Redirect target uses the pre-update topic, matching the old error
          # path that redirected using the topic from the plug assigns.
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Locks a topic to prevent further posting.

  This is the internal lock engine shared with `lock_topic/4`; it performs no
  authorization and writes no moderation log, so controller-facing callers go
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
  unlock is rejected (so the controller can redirect back to the topic),
  `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unlock_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unlock_topic(User.t() | nil, String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def unlock_topic(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case unlock_topic(topic) do
        {:ok, unlocked_topic} ->
          # Body reads the title off the post-unlock topic; forum name off the
          # separately loaded forum. Byte-for-byte the retired `log_details/2`.
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
  authorization and writes no moderation log, so controller-facing callers go
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
  it, exactly as the retired LoadTopicPlug `show_hidden: false` chain behaved),
  and the `:hide` permission on the topic is then checked. Only after
  authorization is the target forum id parsed and the move attempted, so an
  unprivileged actor sending a malformed target still gets unauthorized. On
  success the NEW forum is preloaded (needed for both the redirect target and
  the log body), post/topic counts are updated for both forums, and a
  moderation log is written attributing the move to the actor.

  Returns `{:ok, {new_forum, topic}}` on success (the new forum is where the
  controller redirects), `{:error, forum, topic}` carrying the SOURCE forum and
  topic when the move cannot happen for a reason the controller renders as a
  flash + redirect back (a missing or non-integer target id, or a well-formed
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
  @spec move_topic(User.t() | nil, String.t(), String.t(), map() | nil) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def move_topic(actor, forum_slug, topic_slug, topic_params) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      # Target id parsing happens only after authorization, so an unprivileged
      # actor with a malformed target still answers unauthorized rather than the
      # bespoke failure. A missing or non-integer target and a well-formed id
      # for a nonexistent forum all funnel to the inner else, which redirects
      # back to the SOURCE topic - so it carries the source `forum` and `topic`.
      with {:ok, target_forum_id} <- parse_target_forum_id(topic_params),
           {:ok, %{topic: moved_topic}} <- move_topic(topic, target_forum_id) do
        # The old controller force-preloaded the NEW forum off the moved topic
        # for both the redirect target and the log body; that preload lives here
        # now. The body reproduces the retired `log_details/2` string
        # byte-for-byte.
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
  # `target_forum_id` all collapse to `:error`, matching the retired
  # IntegerId-based controller and its missing-param fallback clause.
  defp parse_target_forum_id(topic_params) do
    (topic_params || %{})
    |> Map.get("target_forum_id")
    |> IntegerId.parse()
  end

  @doc """
  Moves a topic to a different forum, updating post counts for both forums.

  This is the internal move engine shared with `move_topic/4`; it performs no
  authorization and writes no moderation log, so controller-facing callers go
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
  `:show` it, exactly as the retired LoadTopicPlug `show_hidden: false` chain
  behaved), and the `:hide` permission on the topic is then checked. On success
  the forum post/topic counts are updated, the topic's posts are reindexed, and
  a moderation log is written attributing the deletion to the actor.

  Returns `{:ok, {forum, topic}}` on success (both are needed to redirect back
  to the topic), `{:error, forum, topic}` when the hide changeset is rejected
  (e.g. a blank reason, so the controller can still redirect back to the
  topic), `{:error, :unauthorized}` when the actor may not see the forum/topic
  or hide the topic, or `{:error, :not_found}` when the topic does not exist.

  ## Examples

      iex> hide_topic(moderator, "dis", "some-topic", "Rule violation")
      {:ok, {%Forum{}, %Topic{}}}

      iex> hide_topic(moderator, "dis", "some-topic", "")
      {:error, %Forum{}, %Topic{}}

  """
  @spec hide_topic(User.t() | nil, String.t(), String.t(), String.t() | nil) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def hide_topic(actor, forum_slug, topic_slug, deletion_reason) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case hide_topic(topic, deletion_reason, actor) do
        {:ok, hidden_topic} ->
          # The body reads the reason and title off the post-update topic, and
          # the forum name off the separately loaded forum (the loaded topic
          # carries no preloaded `:forum`). This reproduces the retired
          # `log_details/2` string byte-for-byte.
          ModerationLogs.create_moderation_log(
            actor,
            "Topic.Hide:create",
            Paths.topic_path(forum, hidden_topic),
            "Deleted topic '#{hidden_topic.title}' (#{hidden_topic.deletion_reason}) in #{forum.name}"
          )

          {:ok, {forum, hidden_topic}}

        {:error, %Ecto.Changeset{}} ->
          # Redirect target uses the pre-update topic, matching the old error
          # path that redirected using the topic from the plug assigns.
          {:error, forum, topic}
      end
    end
  end

  @doc """
  Hides a topic and updates related forum data.

  This is the internal hide engine shared with `hide_topic/4` and
  `Philomena.Users.Eraser`; it performs no authorization and writes no
  moderation log, so controller-facing callers go through `hide_topic/4`.

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
  restore is rejected (so the controller can redirect back to the topic),
  `{:error, :unauthorized}`, or `{:error, :not_found}`.

  ## Examples

      iex> unhide_topic(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}}}

  """
  @spec unhide_topic(User.t() | nil, String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def unhide_topic(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         :ok <- authorize(actor, :hide, topic) do
      case unhide_topic(topic) do
        {:ok, restored_topic} ->
          # Body reads the title off the post-restore topic; forum name off the
          # separately loaded forum. Byte-for-byte the retired `log_details/2`.
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
  authorization and writes no moderation log, so controller-facing callers go
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
