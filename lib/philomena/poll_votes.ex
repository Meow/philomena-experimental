defmodule Philomena.PollVotes do
  @moduledoc """
  Poll voting, staff result inspection, and vote removal.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.PollOptions
  alias Philomena.PollOptions.PollOption
  alias Philomena.Polls
  alias Philomena.Polls.{Poll, TopicPoll}
  alias Philomena.PollVotes.{Ballot, PollVote}
  alias Philomena.Multi
  alias Philomena.Repo
  alias Philomena.Users.User

  defp user_voted?(%Poll{id: poll_id}, %User{id: user_id}) do
    PollVote
    |> join(:inner, [vote], option in assoc(vote, :poll_option))
    |> where([vote, option], option.poll_id == ^poll_id and vote.user_id == ^user_id)
    |> Repo.exists?()
  end

  defp load_poll_vote(poll, vote_id) do
    PollVote
    |> join(:inner, [vote], option in assoc(vote, :poll_option))
    |> where([_vote, option], option.poll_id == ^poll.id)
    |> Loader.fetch(vote_id)
  end

  @doc """
  Lists voter identities for the parent-scoped poll.

  This is a separate staff-only ability from viewing aggregate poll results.

  ## Examples

      iex> list_votes(moderator_actor, "dis", "favorite-pony")
      {:ok, [%PollOption{}]}

  """
  @spec list_votes(Actor.t(), String.t(), String.t()) ::
          {:ok, [PollOption.t()]} | {:error, :not_found | :unauthorized}
  def list_votes(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, result} <-
           Polls.load_topic_poll(actor, forum_slug, topic_slug, :list_poll_votes) do
      {:ok,
       PollOption
       |> where(poll_id: ^result.poll.id)
       |> where([option], option.vote_count > 0)
       |> preload(poll_votes: :user)
       |> Repo.all()}
    end
  end

  @doc """
  Records a complete, validated vote selection for the parent-scoped poll.

  Every option must exist under that poll, IDs must be unique, single-choice
  polls accept exactly one option, and multiple-choice polls accept at least
  one. The poll is locked before its active and prior-vote invariants are
  checked. Any failure rejects the entire selection with a changeset.

  ## Examples

      iex> create_votes(actor, "dis", "favorite-pony", %{"option_ids" => ["1"]})
      {:ok, %Ballot{}}

      iex> create_votes(actor, "dis", "favorite-pony", %{"option_ids" => ["bad"]})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_votes(Actor.t(), String.t(), String.t(), map() | nil) ::
          {:ok, Ballot.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def create_votes(%Actor{user: user} = actor, forum_slug, topic_slug, params) do
    with :ok <- verify_write_access(actor),
         {:ok, result} <- Polls.load_topic_poll(actor, forum_slug, topic_slug, :vote) do
      poll = result.poll
      options = PollOptions.load_options(poll)
      poll_query = where(Poll, id: ^poll.id)

      Multi.new()
      |> Multi.lock_one(:poll, preload(poll_query, topic: :forum))
      |> Multi.run(:ballot, fn _repo, %{poll: poll} ->
        %Ballot{poll: poll}
        |> Ballot.changeset(params, poll, Enum.map(options, & &1.id))
        |> Ballot.validate_active(Polls.active?(poll))
        |> Ballot.validate_not_voted(user_voted?(poll, user))
        |> Ecto.Changeset.apply_action(:create)
      end)
      |> Multi.insert_all(:poll_votes, PollVote, fn %{ballot: ballot} ->
        now = DateTime.utc_now(:second)

        Enum.map(ballot.option_ids, &%{poll_option_id: &1, user_id: user.id, created_at: now})
      end)
      |> Multi.run(:update_options, fn repo, %{ballot: ballot, poll: poll} ->
        {count, nil} =
          PollOption
          |> where([option], option.id in ^ballot.option_ids and option.poll_id == ^poll.id)
          |> repo.update_all(inc: [vote_count: 1])

        {:ok, count}
      end)
      |> Multi.run(:update_poll, fn repo, %{poll_votes: {count, _}} ->
        {count, nil} = repo.update_all(poll_query, inc: [total_votes: count])

        {:ok, count}
      end)
      |> Multi.transact()
      |> case do
        {:ok, %{ballot: ballot}} ->
          {:ok, ballot}

        {:error, :ballot, changeset, _changes} ->
          {:error, changeset}
      end
    end
  end

  @doc """
  Removes one vote belonging to the parent-scoped poll.

  Cached option and poll totals are decremented in the same transaction.

  ## Examples

      iex> delete_vote(moderator_actor, "dis", "favorite-pony", "1")
      {:ok, %TopicPoll{}}

  """
  @spec delete_vote(Actor.t(), String.t(), String.t(), IntegerId.integer_id()) ::
          {:ok, TopicPoll.t()} | {:error, :ban | :not_found | :unauthorized}
  def delete_vote(%Actor{} = actor, forum_slug, topic_slug, vote_id) do
    with :ok <- verify_write_access(actor),
         {:ok, result} <-
           Polls.load_topic_poll(actor, forum_slug, topic_slug, :delete_poll_vote),
         {:ok, poll_vote} <- load_poll_vote(result.poll, vote_id) do
      poll_option_query = where(PollOption, id: ^poll_vote.poll_option_id)
      poll_query = where(Poll, id: ^result.poll.id)

      # TODO: gracefully handle Ecto.StaleEntryError
      {:ok, _changes} =
        Multi.new()
        |> Multi.delete(:poll_vote, poll_vote)
        |> Multi.update_all(:update_options, poll_option_query, inc: [vote_count: -1])
        |> Multi.update_all(:update_poll, poll_query, inc: [total_votes: -1])
        |> Multi.transact()

      {:ok, result}
    end
  end

  @doc """
  Returns whether `actor`'s signed-in user has voted in a loaded poll.

  ## Examples

      iex> voted?(actor, poll)
      false

  """
  @spec voted?(Actor.t(), Poll.t() | nil) :: boolean()
  def voted?(%Actor{user: %User{} = user}, %Poll{} = poll), do: user_voted?(poll, user)
  def voted?(%Actor{}, _poll), do: false
end
