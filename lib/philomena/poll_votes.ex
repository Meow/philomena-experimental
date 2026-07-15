defmodule Philomena.PollVotes do
  @moduledoc """
  The PollVotes context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Attribution.Actor
  alias Philomena.IntegerId
  alias Philomena.Topics
  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic
  alias Philomena.Polls
  alias Philomena.Polls.Poll
  alias Philomena.PollVotes.PollVote
  alias Philomena.PollOptions.PollOption

  @doc """
  Lists the poll options carrying at least one vote for the poll attached to the
  topic named by `topic_slug` within the forum named by `forum_slug`, on behalf
  of `actor` (the acting user), with each option's votes and their voters
  preloaded.

  In order: the forum is loaded by short name and authorized for `:show`, the
  topic is loaded by slug with hidden topics kept invisible unless the actor may
  `:show` them, the poll is loaded (a topic with no poll is
  `{:error, :not_found}`), and only then is the `:hide` permission on the topic
  checked. Options with no votes are dropped, so only options someone voted for
  are returned.

  Returns `{:ok, options}` (the options someone voted for),
  `{:error, :unauthorized}` when the actor may not see the forum/topic or hide
  the topic, or `{:error, :not_found}` when the topic or its poll does not exist.

  ## Examples

      iex> list_votes(moderator, "dis", "some-topic")
      {:ok, [%PollOption{}]}

  """
  @spec list_votes(Actor.t(), String.t(), String.t()) ::
          {:ok, [PollOption.t()]} | {:error, :unauthorized | :not_found}
  def list_votes(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, _forum, topic, poll} <- load_forum_topic_poll(actor.user, forum_slug, topic_slug),
         :ok <- authorize(actor, :hide, topic) do
      {:ok, voted_options(poll)}
    end
  end

  defp voted_options(poll) do
    PollOption
    |> where(poll_id: ^poll.id)
    |> where([po], po.vote_count > 0)
    |> preload(poll_votes: :user)
    |> Repo.all()
  end

  @doc """
  Records `actor`'s votes on the poll attached to the topic named by `topic_slug`
  within the forum named by `forum_slug` from `poll_params`.

  `verify_write_access/1` runs first, before any loading: a banned actor is
  `{:error, :ban}` and an actor with no fingerprint is `{:error, :unauthorized}`,
  neither having touched the poll. Then the forum is loaded by short name and
  authorized for `:show`, the topic is loaded by slug with hidden topics kept
  invisible unless the actor may `:show` them, and the poll is loaded (a topic
  with no poll is `{:error, :not_found}`). Unlike listing and deleting votes,
  there is no `:hide` check: recording a vote is open to any signed-in actor who
  passes the ban filter.

  `poll_params` may be `nil` when
  the caller submitted no poll data. A `nil` (or otherwise non-map) params value
  records nothing and is reported as a failure; a map is handed to
  `create_poll_votes/3`, whose own filtering silently drops expired polls, repeat
  voters, and option ids that do not belong to the poll.

  Returns `{:ok, {forum, topic}}` when the votes are recorded,
  `{:error, forum, topic}` when nothing is recorded (both carry the topic for the
  caller to reuse), `{:error, :ban}` or `{:error, :unauthorized}` from the
  write-access check, `{:error, :unauthorized}` when the forum/topic is not
  visible, or `{:error, :not_found}` when the topic or its poll does not exist.

  ## Examples

      iex> create_votes(actor, "dis", "some-topic", %{"option_ids" => ["1"]})
      {:ok, {%Forum{}, %Topic{}}}

      iex> create_votes(actor, "dis", "some-topic", nil)
      {:error, %Forum{}, %Topic{}}

  """
  @spec create_votes(Actor.t(), String.t(), String.t(), map() | nil) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :ban | :unauthorized | :not_found}
  def create_votes(%Actor{} = actor, forum_slug, topic_slug, poll_params) do
    with :ok <- verify_write_access(actor),
         {:ok, forum, topic, poll} <- load_forum_topic_poll(actor.user, forum_slug, topic_slug) do
      record_votes(actor.user, forum, topic, poll, poll_params)
    end
  end

  defp record_votes(user, forum, topic, poll, %{} = poll_params) do
    case create_poll_votes(user, poll, poll_params) do
      {:ok, _votes} -> {:ok, {forum, topic}}
      _error -> {:error, forum, topic}
    end
  end

  # No poll params were submitted; report a failure without recording anything.
  defp record_votes(_user, forum, topic, _poll, _poll_params), do: {:error, forum, topic}

  @doc """
  Removes the poll vote named by `vote_id` from the poll attached to the topic
  named by `topic_slug` within the forum named by `forum_slug`, on behalf of
  `actor` (the acting user).

  In order: forum `:show`, topic visibility, poll existence, then the `:hide`
  permission on the topic, all before the vote is even looked up. `vote_id` is
  then parsed with `Philomena.IntegerId`; a non-integer id, or an integer naming
  no vote, takes the bespoke failure path `{:error, forum, topic}` with the topic
  for the caller to reuse, rather than raising. A found vote is deleted (decrementing
  the cached option and poll tallies).

  Returns `{:ok, {forum, topic}}` when the vote is removed,
  `{:error, forum, topic}` when no vote matches `vote_id`,
  `{:error, :unauthorized}` when the actor may not see the forum/topic or hide
  the topic, or `{:error, :not_found}` when the topic or its poll does not exist.

  ## Examples

      iex> delete_vote(moderator, "dis", "some-topic", "1")
      {:ok, {%Forum{}, %Topic{}}}

      iex> delete_vote(moderator, "dis", "some-topic", "999")
      {:error, %Forum{}, %Topic{}}

  """
  @spec delete_vote(Actor.t(), String.t(), String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t()}
          | {:error, :unauthorized | :not_found}
  def delete_vote(%Actor{} = actor, forum_slug, topic_slug, vote_id) do
    with {:ok, forum, topic, _poll} <- load_forum_topic_poll(actor.user, forum_slug, topic_slug),
         :ok <- authorize(actor, :hide, topic) do
      case load_poll_vote(vote_id) do
        nil ->
          {:error, forum, topic}

        poll_vote ->
          {:ok, _poll_vote} = delete_poll_vote(poll_vote)
          {:ok, {forum, topic}}
      end
    end
  end

  defp load_poll_vote(vote_id) do
    case IntegerId.parse(vote_id) do
      {:ok, id} -> get_poll_vote(id)
      :error -> nil
    end
  end

  # Shared loader for the vote operations: forum `:show`, topic visibility (hidden
  # topics stay invisible without `:show`), then poll existence. The `:hide`
  # check is deliberately left to the index/delete callers, since create does
  # not gate on it.
  defp load_forum_topic_poll(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         {:ok, poll} <- Polls.load_poll(topic) do
      {:ok, forum, topic, poll}
    end
  end

  @doc """
  Gets a single poll_vote.

  Raises `Ecto.NoResultsError` if the Poll vote does not exist.

  ## Examples

      iex> get_poll_vote!(123)
      %PollVote{}

      iex> get_poll_vote!(456)
      ** (Ecto.NoResultsError)

  """
  def get_poll_vote!(id), do: Repo.get!(PollVote, id)

  @doc """
  Gets a single poll_vote, or nil when no vote has the given id.

  ## Examples

      iex> get_poll_vote(123)
      %PollVote{}

      iex> get_poll_vote(456)
      nil

  """
  def get_poll_vote(id), do: Repo.get(PollVote, id)

  @doc """
  Creates a poll_vote.

  ## Examples

      iex> create_poll_vote(%{field: value})
      {:ok, %PollVote{}}

      iex> create_poll_vote(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_poll_votes(user, poll, attrs) do
    now = DateTime.utc_now(:second)
    poll_votes = filter_options(user, poll, now, attrs)

    Multi.new()
    |> Multi.run(:lock, fn repo, _ ->
      poll =
        Poll
        |> where(id: ^poll.id)
        |> lock("FOR UPDATE")
        |> repo.one()

      {:ok, poll}
    end)
    |> Multi.run(:ended, fn _repo, _changes ->
      # Bail if poll is no longer active
      if Polls.active?(poll) do
        {:ok, []}
      else
        {:error, []}
      end
    end)
    |> Multi.run(:existing_votes, fn _repo, _changes ->
      # Don't proceed if any votes exist
      if voted?(poll, user) do
        {:error, []}
      else
        {:ok, []}
      end
    end)
    |> Multi.run(:new_votes, fn repo, _changes ->
      {_count, votes} = repo.insert_all(PollVote, poll_votes, returning: true)

      {:ok, votes}
    end)
    |> Multi.run(:update_option_counts, fn repo, %{new_votes: new_votes} ->
      option_ids = Enum.map(new_votes, & &1.poll_option_id)

      {count, nil} =
        PollOption
        |> where([po], po.id in ^option_ids)
        |> repo.update_all(inc: [vote_count: 1])

      {:ok, count}
    end)
    |> Multi.run(:update_poll_votes_count, fn repo, %{new_votes: new_votes} ->
      length = length(new_votes)

      {count, nil} =
        Poll
        |> where(id: ^poll.id)
        |> repo.update_all(inc: [total_votes: length])

      {:ok, count}
    end)
    |> Repo.transaction()
  end

  defp filter_options(user, poll, now, %{"option_ids" => options}) when is_list(options) do
    valid_option_ids = poll_option_ids(poll)

    votes =
      options
      |> Enum.map(&parse_option_id/1)
      |> Enum.filter(&MapSet.member?(valid_option_ids, &1))
      |> Enum.uniq()
      |> Enum.map(&%{poll_option_id: &1, user_id: user.id, created_at: now})

    case poll.vote_method do
      "single" -> Enum.take(votes, 1)
      _other -> votes
    end
  end

  defp filter_options(_user, _poll, _now, _attrs), do: []

  defp poll_option_ids(poll) do
    PollOption
    |> where(poll_id: ^poll.id)
    |> select([po], po.id)
    |> Repo.all()
    |> MapSet.new()
  end

  defp parse_option_id(option_id) when is_binary(option_id) do
    case Integer.parse(option_id) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp parse_option_id(option_id) when is_integer(option_id), do: option_id
  defp parse_option_id(_option_id), do: nil

  def voted?(nil, _user), do: false
  def voted?(_poll, nil), do: false

  def voted?(%{id: poll_id}, %{id: user_id}) do
    PollVote
    |> join(:inner, [pv], _ in assoc(pv, :poll_option))
    |> where([pv, po], po.poll_id == ^poll_id and pv.user_id == ^user_id)
    |> Repo.exists?()
  end

  @doc """
  Updates a poll_vote.

  ## Examples

      iex> update_poll_vote(poll_vote, %{field: new_value})
      {:ok, %PollVote{}}

      iex> update_poll_vote(poll_vote, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_poll_vote(%PollVote{} = poll_vote, attrs) do
    poll_vote
    |> PollVote.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a PollVote.

  ## Examples

      iex> delete_poll_vote(poll_vote)
      {:ok, %PollVote{}}

      iex> delete_poll_vote(poll_vote)
      {:error, %Ecto.Changeset{}}

  """
  def delete_poll_vote(%PollVote{} = poll_vote) do
    Multi.new()
    |> Multi.delete(:poll_vote, poll_vote)
    |> Multi.run(:update_option_count, fn repo, _changes ->
      {_count, [poll_id]} =
        PollOption
        |> where(id: ^poll_vote.poll_option_id)
        |> select([po], po.poll_id)
        |> repo.update_all(inc: [vote_count: -1])

      {:ok, poll_id}
    end)
    |> Multi.run(:update_poll_votes_count, fn repo, %{update_option_count: poll_id} ->
      {count, nil} =
        Poll
        |> where(id: ^poll_id)
        |> repo.update_all(inc: [total_votes: -1])

      {:ok, count}
    end)
    |> Repo.transaction()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking poll_vote changes.

  ## Examples

      iex> change_poll_vote(poll_vote)
      %Ecto.Changeset{source: %PollVote{}}

  """
  def change_poll_vote(%PollVote{} = poll_vote) do
    PollVote.changeset(poll_vote, %{})
  end
end
