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
  alias Philomena.PollVotes.{PollVote, VoteForm}
  alias Philomena.Repo
  alias Philomena.Users.User

  defp vote_error(field, message) do
    %PollVote{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, message)
  end

  defp vote_form(%TopicPoll{} = result, changeset) do
    %VoteForm{
      forum: result.forum,
      topic: result.topic,
      poll: result.poll,
      changeset: changeset
    }
  end

  defp selected_options(%Poll{} = poll, %{"option_ids" => option_ids}) do
    with {:ok, options} <- PollOptions.load_selected_options(poll, option_ids),
         :ok <- validate_selection_count(poll, options) do
      {:ok, options}
    else
      {:error, :duplicate} ->
        {:error, vote_error(:poll_option_id, "contains duplicate choices")}

      {:error, :not_found} ->
        {:error, vote_error(:poll_option_id, "contains an invalid choice")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  defp selected_options(_poll, _attrs),
    do: {:error, vote_error(:poll_option_id, "must select a choice")}

  defp validate_selection_count(%Poll{vote_method: "single"}, [_option]), do: :ok

  defp validate_selection_count(%Poll{vote_method: "single"}, _options),
    do: {:error, vote_error(:poll_option_id, "must select exactly one choice")}

  defp validate_selection_count(%Poll{vote_method: "multiple"}, [_option | _rest]), do: :ok

  defp validate_selection_count(_poll, _options),
    do: {:error, vote_error(:poll_option_id, "must select at least one choice")}

  defp persist_poll_votes(%User{} = user, %Poll{} = poll, options) do
    Repo.transact(fn ->
      with {:ok, locked_poll} <- lock_poll(poll),
           :ok <- validate_active(locked_poll),
           :ok <- validate_not_voted(locked_poll, user) do
        now = DateTime.utc_now(:second)

        rows =
          Enum.map(options, &%{poll_option_id: &1.id, user_id: user.id, created_at: now})

        {_count, votes} = Repo.insert_all(PollVote, rows, returning: true)
        option_ids = Enum.map(options, & &1.id)

        PollOption
        |> where([option], option.id in ^option_ids and option.poll_id == ^locked_poll.id)
        |> Repo.update_all(inc: [vote_count: 1])

        Poll
        |> where(id: ^locked_poll.id)
        |> Repo.update_all(inc: [total_votes: length(votes)])

        {:ok, votes}
      end
    end)
  end

  defp lock_poll(%Poll{id: poll_id}) do
    Poll
    |> where(id: ^poll_id)
    |> lock("FOR UPDATE")
    |> Loader.one()
  end

  defp validate_active(poll) do
    if Polls.active?(poll) do
      :ok
    else
      {:error, vote_error(:poll_option_id, "poll is closed")}
    end
  end

  defp validate_not_voted(poll, user) do
    if user_voted?(poll, user) do
      {:error, vote_error(:user_id, "has already voted")}
    else
      :ok
    end
  end

  defp user_voted?(%Poll{id: poll_id}, %User{id: user_id}) do
    PollVote
    |> join(:inner, [vote], option in assoc(vote, :poll_option))
    |> where([vote, option], option.poll_id == ^poll_id and vote.user_id == ^user_id)
    |> Repo.exists?()
  end

  defp voted_options(poll) do
    PollOption
    |> where(poll_id: ^poll.id)
    |> where([option], option.vote_count > 0)
    |> preload(poll_votes: :user)
    |> Repo.all()
  end

  defp load_poll_vote(poll, vote_id) do
    case IntegerId.parse(vote_id) do
      {:ok, vote_id} ->
        PollVote
        |> join(:inner, [vote], option in assoc(vote, :poll_option))
        |> where([vote, option], vote.id == ^vote_id and option.poll_id == ^poll.id)
        |> Loader.one()

      :error ->
        {:error, :not_found}
    end
  end

  defp delete_poll_vote(%PollVote{} = poll_vote, %Poll{} = poll) do
    Repo.transact(fn ->
      with {:ok, poll_vote} <-
             PollVote
             |> where(id: ^poll_vote.id)
             |> lock("FOR UPDATE")
             |> Loader.one(),
           {:ok, option} <- PollOptions.load_option(poll, poll_vote.poll_option_id),
           {:ok, _vote} <- Repo.delete(poll_vote) do
        PollOption
        |> where(id: ^option.id)
        |> Repo.update_all(inc: [vote_count: -1])

        Poll
        |> where(id: ^poll.id)
        |> Repo.update_all(inc: [total_votes: -1])

        {:ok, poll_vote}
      end
    end)
  end

  @doc false
  @spec create_poll_votes(User.t(), Poll.t(), map()) ::
          {:ok, [PollVote.t()]} | {:error, Ecto.Changeset.t()}
  def create_poll_votes(%User{} = user, %Poll{} = poll, attrs) do
    with {:ok, options} <- selected_options(poll, attrs) do
      persist_poll_votes(user, poll, options)
    end
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
      {:ok, voted_options(result.poll)}
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
      {:ok, %TopicPoll{}}

      iex> create_votes(actor, "dis", "favorite-pony", %{"option_ids" => ["bad"]})
      {:error, %VoteForm{}}

  """
  @spec create_votes(Actor.t(), String.t(), String.t(), map() | nil) ::
          {:ok, TopicPoll.t()}
          | {:error, VoteForm.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def create_votes(%Actor{user: %User{}} = actor, forum_slug, topic_slug, params) do
    with :ok <- verify_write_access(actor),
         {:ok, result} <- Polls.load_topic_poll(actor, forum_slug, topic_slug, :vote),
         {:ok, options} <- selected_options(result.poll, params),
         {:ok, _votes} <- persist_poll_votes(actor.user, result.poll, options) do
      {:ok, result}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        with {:ok, result} <- Polls.load_topic_poll(actor, forum_slug, topic_slug, :vote) do
          {:error, vote_form(result, changeset)}
        end

      error ->
        error
    end
  end

  def create_votes(%Actor{} = actor, _forum_slug, _topic_slug, _params) do
    with :ok <- verify_write_access(actor) do
      {:error, :unauthorized}
    end
  end

  @doc """
  Removes one vote only when it belongs to the parent-scoped poll.

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
         {:ok, poll_vote} <- load_poll_vote(result.poll, vote_id),
         {:ok, _poll_vote} <- delete_poll_vote(poll_vote, result.poll) do
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
