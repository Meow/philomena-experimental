defmodule Philomena.Polls do
  @moduledoc """
  The Polls context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Attribution.Actor
  alias Philomena.Repo
  alias Philomena.Topics
  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic
  alias Philomena.Polls.Poll

  # Updates a poll.
  defp update_poll(%Poll{} = poll, attrs) do
    poll
    |> Poll.changeset(attrs)
    |> Repo.update()
  end

  # Returns an `%Ecto.Changeset{}` for tracking poll changes.
  defp change_poll(%Poll{} = poll) do
    Poll.changeset(poll, %{})
  end

  @doc """
  Loads the poll attached to the topic named by `topic_slug` within the forum
  named by `forum_slug` for editing, on behalf of `actor`.

  The forum is loaded by short name and authorized for `:show`, the topic is
  loaded by slug with hidden topics kept invisible unless the actor may `:show` them,
  the poll is loaded, and the `:hide` permission on the topic is checked.
  The poll's options are preloaded so the existing choices are available.

  Returns `{:ok, {forum, topic, poll, changeset}}` (the forum and topic are
  returned for the caller to reuse, and the changeset tracks changes to the
  poll), `{:error, :unauthorized}` when the actor may not see the forum/topic
  or hide the topic, or `{:error, :not_found}` when the topic or its poll does
  not exist.

  ## Examples

      iex> load_poll_for_edit(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}, %Poll{}, %Ecto.Changeset{}}}

  """
  @spec load_poll_for_edit(actor :: Actor.t(), forum_slug :: String.t(), topic_slug :: String.t()) ::
          {:ok, {Forum.t(), Topic.t(), Poll.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def load_poll_for_edit(%Actor{} = actor, forum_slug, topic_slug) do
    with {:ok, forum, topic, poll} <- load_forum_topic_poll(actor, forum_slug, topic_slug) do
      {:ok, {forum, topic, poll, change_poll(poll)}}
    end
  end

  # The forum `:show`, topic visibility, poll existence, and topic `:hide` checks
  # run in that order. Options are preloaded here so the existing choices are
  # present for editing and on the update-error path.
  defp load_forum_topic_poll(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           Topics.load_forum_topic(actor.user, forum_slug, topic_slug, show_hidden: false),
         {:ok, poll} <- load_poll(topic),
         :ok <- authorize(actor, :hide, topic) do
      {:ok, forum, topic, Repo.preload(poll, :options)}
    end
  end

  @doc """
  Loads the poll attached to `topic`.

  Returns `{:ok, poll}`, or `{:error, :not_found}` when the topic has no poll.
  """
  @spec load_poll(Topic.t()) :: {:ok, Poll.t()} | {:error, :not_found}
  def load_poll(topic) do
    Poll
    |> where(topic_id: ^topic.id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      poll -> {:ok, poll}
    end
  end

  @doc """
  Updates the poll attached to the topic named by `topic_slug` within the forum
  named by `forum_slug` from `poll_params`, on behalf of `actor` (the acting
  user).

  Loading and authorization mirror `load_poll_for_edit/3` exactly, so an actor
  who may not edit the poll never reaches the update.

  Returns `{:ok, {forum, topic}}` on success (both are returned for the caller
  to reuse), `{:error, forum, topic, changeset}` when the poll changeset is
  rejected (the forum, topic, and changeset are returned for the caller to
  reuse), `{:error, :unauthorized}` when the actor may not see the forum/topic or
  hide the topic, or `{:error, :not_found}` when the topic or its poll does not exist.

  ## Examples

      iex> update_poll(moderator, "dis", "some-topic", %{"title" => "New title"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> update_poll(moderator, "dis", "some-topic", %{"title" => ""})
      {:error, %Forum{}, %Topic{}, %Ecto.Changeset{}}

  """
  @spec update_poll(
          actor :: Actor.t(),
          forum_slug :: String.t(),
          topic_slug :: String.t(),
          poll_params :: map()
        ) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | :not_found}
  def update_poll(%Actor{} = actor, forum_slug, topic_slug, poll_params) do
    with {:ok, forum, topic, poll} <- load_forum_topic_poll(actor, forum_slug, topic_slug) do
      case update_poll(poll, poll_params) do
        {:ok, _poll} ->
          {:ok, {forum, topic}}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, forum, topic, changeset}
      end
    end
  end

  @doc """
  Returns whether the given poll is currently active.

  ## Examples

      iex> active?(poll)
      true

  """
  @spec active?(Poll.t()) :: boolean()
  def active?(%Poll{id: poll_id}) do
    now = DateTime.utc_now()

    Poll
    |> where([p], p.id == ^poll_id and p.active_until > ^now)
    |> Repo.exists?()
  end

  def active?(_poll), do: false
end
