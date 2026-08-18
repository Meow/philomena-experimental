defmodule Philomena.Polls do
  @moduledoc """
  Poll forms, updates, and shared services for voting.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.Loader
  alias Philomena.Polls.{Poll, PollForm, TopicPoll}
  alias Philomena.Multi
  alias Philomena.Forums
  alias Philomena.Topics

  defp poll_form(%TopicPoll{} = result, changeset \\ nil) do
    %PollForm{
      forum: result.forum,
      topic: result.topic,
      poll: result.poll,
      changeset: changeset || Poll.changeset(result.poll)
    }
  end

  @doc """
  Loads a poll through its route forum and topic and authorizes `action` on the
  topic before returning it.

  This service is shared with `Philomena.PollVotes`; callers cannot load
  a poll independently of an authorized parent chain.

  ## Examples

      iex> load_topic_poll(actor, "dis", "favorite-pony", :vote)
      {:ok, %TopicPoll{}}

      iex> load_topic_poll(actor, "dis", "topic-without-poll", :vote)
      {:error, :not_found}

  """
  @spec load_topic_poll(Actor.t(), String.t(), String.t(), atom()) ::
          {:ok, TopicPoll.t()} | {:error, :not_found | :unauthorized}
  def load_topic_poll(%Actor{} = actor, forum_slug, topic_slug, action) do
    with {:ok, forum} <- Forums.load_forum(actor, forum_slug),
         {:ok, topic} <- Topics.load_forum_topic(actor, forum, topic_slug, :show),
         {:ok, poll} <-
           Poll
           |> where([poll], poll.topic_id == ^topic.id)
           |> preload(:options)
           |> Loader.one(),
         :ok <- authorize(actor, action, topic) do
      {:ok, %TopicPoll{forum: forum, topic: topic, poll: poll}}
    end
  end

  @doc """
  Loads an authorized poll edit form.

  Existing options are included in the form.

  ## Examples

      iex> load_poll_for_edit(moderator_actor, "dis", "favorite-pony")
      {:ok, %PollForm{}}

  """
  @spec load_poll_for_edit(Actor.t(), String.t(), String.t()) ::
          {:ok, PollForm.t()} | {:error, :ban | :not_found | :unauthorized}
  def load_poll_for_edit(%Actor{} = actor, forum_slug, topic_slug) do
    with :ok <- verify_write_access(actor),
         {:ok, result} <- load_topic_poll(actor, forum_slug, topic_slug, :edit_poll) do
      {:ok, poll_form(result)}
    end
  end

  @doc """
  Updates the poll beneath the authorized route topic.

  The poll is row-locked while it and its options update transactionally. Invalid
  close times, vote methods, titles, or option sets return a form carrying the
  rejected changeset. Once voting has started, the vote method and options are
  immutable so existing votes retain their meaning; the title and end time may
  still be changed.

  ## Examples

      iex> update_poll(moderator_actor, "dis", "favorite-pony", attrs)
      {:ok, %TopicPoll{}}

      iex> update_poll(moderator_actor, "dis", "favorite-pony", invalid_attrs)
      {:error, %PollForm{}}

  """
  @spec update_poll(Actor.t(), String.t(), String.t(), map()) ::
          {:ok, TopicPoll.t()}
          | {:error, PollForm.t()}
          | {:error, :ban | :not_found | :unauthorized}
  def update_poll(%Actor{} = actor, forum_slug, topic_slug, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, result} <- load_topic_poll(actor, forum_slug, topic_slug, :update_poll) do
      poll_query =
        Poll
        |> where(id: ^result.poll.id)
        |> preload(:options)

      Multi.new()
      |> Multi.lock_one(:locked_poll, poll_query)
      |> Multi.update(:poll, fn %{locked_poll: poll} -> Poll.changeset(poll, attrs) end)
      |> Multi.transact()
      |> case do
        {:ok, %{poll: poll}} ->
          {:ok, %{result | poll: poll}}

        {:error, :poll, changeset, _changes} ->
          {:error, poll_form(result, changeset)}
      end
    end
  end

  @doc """
  Returns whether a loaded poll is accepting votes at `now`.

  The close instant itself is inactive.

  ## Examples

      iex> active?(poll, DateTime.utc_now())
      true

  """
  @spec active?(Poll.t() | nil, DateTime.t()) :: boolean()
  def active?(poll, now \\ DateTime.utc_now())

  def active?(%Poll{active_until: %DateTime{} = active_until}, %DateTime{} = now),
    do: DateTime.compare(active_until, now) == :gt

  def active?(_poll, _now), do: false
end
