defmodule Philomena.Polls do
  @moduledoc """
  The Polls context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo
  alias Philomena.Topics
  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic
  alias Philomena.Users.User
  alias Philomena.Polls.Poll

  @doc """
  Returns the list of polls.

  ## Examples

      iex> list_polls()
      [%Poll{}, ...]

  """
  def list_polls do
    Repo.all(Poll)
  end

  @doc """
  Gets a single poll.

  Raises `Ecto.NoResultsError` if the Poll does not exist.

  ## Examples

      iex> get_poll!(123)
      %Poll{}

      iex> get_poll!(456)
      ** (Ecto.NoResultsError)

  """
  def get_poll!(id), do: Repo.get!(Poll, id)

  @doc """
  Loads the poll attached to the topic named by `topic_slug` within the forum
  named by `forum_slug` for editing, on behalf of `actor` (the acting user).

  In order: the forum is loaded by short name and authorized for `:show`, the
  topic is loaded by slug with hidden topics kept invisible unless the actor may
  `:show` them, the poll is loaded (a topic with no poll is
  `{:error, :not_found}`), and only then is the `:hide` permission on the topic
  checked. Because the poll load precedes the `:hide` check, a topic with no poll
  answers not-found even for an actor who could not otherwise edit it. The poll's
  options are preloaded so the edit form can render the existing choices.

  Returns `{:ok, {forum, topic, poll, changeset}}` (the forum and topic are
  needed to build the form action, the changeset drives the form),
  `{:error, :unauthorized}` when the actor may not see the forum/topic or hide
  the topic, or `{:error, :not_found}` when the topic or its poll does not exist.

  ## Examples

      iex> load_poll_for_edit(moderator, "dis", "some-topic")
      {:ok, {%Forum{}, %Topic{}, %Poll{}, %Ecto.Changeset{}}}

  """
  @spec load_poll_for_edit(User.t() | nil, String.t(), String.t()) ::
          {:ok, {Forum.t(), Topic.t(), Poll.t(), Ecto.Changeset.t()}}
          | {:error, :unauthorized | :not_found}
  def load_poll_for_edit(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic, poll} <- load_forum_topic_poll(actor, forum_slug, topic_slug) do
      {:ok, {forum, topic, poll, change_poll(poll)}}
    end
  end

  # The forum `:show`, topic visibility, poll existence, and topic `:hide` checks
  # run in that order. Options are preloaded here so both the edit form and the
  # update error re-render can show the existing choices.
  defp load_forum_topic_poll(actor, forum_slug, topic_slug) do
    with {:ok, forum, topic} <-
           Topics.load_forum_topic(actor, forum_slug, topic_slug, show_hidden: false),
         {:ok, poll} <- load_poll(topic),
         :ok <- authorize(actor, :hide, topic) do
      {:ok, forum, topic, Repo.preload(poll, :options)}
    end
  end

  defp load_poll(topic) do
    Poll
    |> where(topic_id: ^topic.id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      poll -> {:ok, poll}
    end
  end

  @doc """
  Creates a poll.

  ## Examples

      iex> create_poll(%{field: value})
      {:ok, %Poll{}}

      iex> create_poll(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_poll(attrs \\ %{}) do
    %Poll{}
    |> Poll.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates the poll attached to the topic named by `topic_slug` within the forum
  named by `forum_slug` from `poll_params`, on behalf of `actor` (the acting
  user).

  Loading and authorization mirror `load_poll_for_edit/3` exactly (forum
  `:show`, topic visibility, poll existence, then topic `:hide`), so an actor
  who may not edit the poll never reaches the update.

  Returns `{:ok, {forum, topic}}` on success (both are needed to redirect back
  to the topic), `{:error, forum, topic, changeset}` when the poll changeset is
  rejected (the forum and topic build the form action and the changeset
  re-renders the edit form),
  `{:error, :unauthorized}` when the actor may not see the forum/topic or hide
  the topic, or `{:error, :not_found}` when the topic or its poll does not exist.

  ## Examples

      iex> update_poll(moderator, "dis", "some-topic", %{"title" => "New title"})
      {:ok, {%Forum{}, %Topic{}}}

      iex> update_poll(moderator, "dis", "some-topic", %{"title" => ""})
      {:error, %Forum{}, %Topic{}, %Ecto.Changeset{}}

  """
  @spec update_poll(User.t() | nil, String.t(), String.t(), map()) ::
          {:ok, {Forum.t(), Topic.t()}}
          | {:error, Forum.t(), Topic.t(), Ecto.Changeset.t()}
          | {:error, :unauthorized | :not_found}
  def update_poll(actor, forum_slug, topic_slug, poll_params) do
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
  Updates a poll.

  This is the internal update engine shared with `update_poll/4`; it performs no
  authorization, so controller-facing callers go through `update_poll/4`.

  ## Examples

      iex> update_poll(poll, %{field: new_value})
      {:ok, %Poll{}}

      iex> update_poll(poll, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_poll(%Poll{} = poll, attrs) do
    poll
    |> Poll.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Poll.

  ## Examples

      iex> delete_poll(poll)
      {:ok, %Poll{}}

      iex> delete_poll(poll)
      {:error, %Ecto.Changeset{}}

  """
  def delete_poll(%Poll{} = poll) do
    Repo.delete(poll)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking poll changes.

  ## Examples

      iex> change_poll(poll)
      %Ecto.Changeset{source: %Poll{}}

  """
  def change_poll(%Poll{} = poll) do
    Poll.changeset(poll, %{})
  end

  def active?(%{id: poll_id}) do
    now = DateTime.utc_now()

    Poll
    |> where([p], p.id == ^poll_id and p.active_until > ^now)
    |> Repo.exists?()
  end

  def active?(_poll), do: false
end
