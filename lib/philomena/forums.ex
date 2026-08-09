defmodule Philomena.Forums do
  @moduledoc """
  Forum discovery, subscription state, and staff-managed forum settings.

  Controller-facing operations load forums by their stable short name before
  authorization. Unknown or malformed names are therefore always not-found.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.Forums.{Forum, ForumIndex, ForumPage}
  alias Philomena.Forums.Visibility
  alias Philomena.Loader
  alias Philomena.Repo
  alias Philomena.Topics.Topic

  use Philomena.Subscriptions, id_name: :forum_id

  defp insert_forum(attrs) do
    %Forum{}
    |> Forum.changeset(attrs)
    |> Repo.insert()
  end

  defp persist_forum_update(%Forum{} = forum, attrs) do
    forum
    |> Forum.changeset(attrs)
    |> Repo.update()
  end

  defp load_authorized_forum(actor, action, short_name) when is_binary(short_name) do
    Forum
    |> where([forum], forum.short_name == ^short_name)
    |> Loader.one_and_authorize(actor, action)
  end

  defp load_authorized_forum(_actor, _action, _short_name), do: {:error, :not_found}

  defp visible_forums_query(actor) do
    Forum
    |> Visibility.visible_forums(actor)
    |> order_by(asc: :name)
    |> preload(last_post: [:user, topic: :forum])
  end

  defp visible_forums(actor), do: actor |> visible_forums_query() |> Repo.all()

  defp visible_topic_count(_actor, []), do: 0

  defp visible_topic_count(actor, forums) do
    forum_ids = Enum.map(forums, & &1.id)

    Topic
    |> where([topic], topic.forum_id in ^forum_ids)
    |> Visibility.visible_topics(actor)
    |> Repo.aggregate(:count)
  end

  defp forum_topics(actor, forum, pagination) do
    Topic
    |> where([topic], topic.forum_id == ^forum.id)
    |> Visibility.visible_topics(actor)
    |> order_by(desc: :sticky, desc: :last_replied_to_at)
    |> preload([:poll, :forum, :user, last_post: :user])
    |> Repo.paginate(pagination)
  end

  @doc false
  @spec create_forum_for_fixture(map()) :: {:ok, Forum.t()} | {:error, Ecto.Changeset.t()}
  def create_forum_for_fixture(attrs \\ %{}), do: insert_forum(attrs)

  @doc """
  Lists the forums visible to `actor`, ordered by name.

  The topic count includes only topics whose parent forum and topic are visible
  to the actor.

  ## Examples

      iex> load_forum_index(actor)
      %ForumIndex{forums: [%Forum{}], topic_count: 42}

  """
  @spec load_forum_index(Actor.t()) :: ForumIndex.t()
  def load_forum_index(%Actor{} = actor) do
    forums = visible_forums(actor)
    %ForumIndex{forums: forums, topic_count: visible_topic_count(actor, forums)}
  end

  @doc """
  Lists the forums visible to `actor` using API pagination.

  ## Examples

      iex> list_forums(actor, pagination)
      %Scrivener.Page{}

  """
  @spec list_forums(Actor.t(), Repo.pagination_params()) :: Scrivener.Page.t(Forum.t())
  def list_forums(%Actor{} = actor, pagination) do
    actor
    |> visible_forums_query()
    |> Repo.paginate(pagination)
  end

  @doc """
  Loads every forum for the staff administration index.

  ## Examples

      iex> load_admin_forums(admin_actor)
      {:ok, [%Forum{}]}

  """
  @spec load_admin_forums(Actor.t()) :: {:ok, [Forum.t()]} | {:error, :unauthorized}
  def load_admin_forums(%Actor{} = actor) do
    with :ok <- authorize(actor, :manage, Forum) do
      {:ok, Repo.all(from forum in Forum, order_by: forum.name)}
    end
  end

  @doc """
  Loads a forum visible to `actor` by short name.

  Malformed or unknown names are not-found; a real restricted forum is
  unauthorized.

  ## Examples

      iex> load_forum(actor, "dis")
      {:ok, %Forum{}}

      iex> load_forum(actor, "missing")
      {:error, :not_found}

  """
  @spec load_forum(Actor.t(), String.t()) ::
          {:ok, Forum.t()} | {:error, :not_found | :unauthorized}
  def load_forum(%Actor{} = actor, short_name) do
    load_authorized_forum(actor, :show, short_name)
  end

  @doc """
  Loads a visible forum and its actor-visible topic page.

  ## Examples

      iex> load_forum_show(actor, "dis", pagination)
      {:ok, %ForumPage{}}

  """
  @spec load_forum_show(Actor.t(), String.t(), Repo.pagination_params()) ::
          {:ok, ForumPage.t()} | {:error, :not_found | :unauthorized}
  def load_forum_show(%Actor{} = actor, short_name, pagination) do
    with {:ok, forum} <- load_authorized_forum(actor, :show, short_name) do
      {:ok,
       %ForumPage{
         forum: forum,
         topics: forum_topics(actor, forum, pagination),
         watching: subscribed?(forum, actor.user)
       }}
    end
  end

  @doc """
  Subscribes `actor` to a visible forum after verifying write access.

  ## Examples

      iex> subscribe(actor, "dis")
      {:ok, %Forum{}}

  """
  @spec subscribe(Actor.t(), String.t()) ::
          {:ok, Forum.t()} | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def subscribe(%Actor{} = actor, short_name) do
    with :ok <- verify_write_access(actor),
         {:ok, forum} <- load_authorized_forum(actor, :subscribe, short_name),
         {:ok, _subscription} <- create_subscription(forum, actor.user) do
      {:ok, forum}
    end
  end

  @doc """
  Idempotently unsubscribes `actor` from a visible forum after verifying write
  access.

  ## Examples

      iex> unsubscribe(actor, "dis")
      {:ok, %Forum{}}

  """
  @spec unsubscribe(Actor.t(), String.t()) ::
          {:ok, Forum.t()} | {:error, :ban | :not_found | :unauthorized}
  def unsubscribe(%Actor{} = actor, short_name) do
    with :ok <- verify_write_access(actor),
         {:ok, forum} <- load_authorized_forum(actor, :unsubscribe, short_name),
         {:ok, _subscription} <- delete_subscription(forum, actor.user) do
      {:ok, forum}
    end
  end

  @doc """
  Builds an authorized forum creation form.

  ## Examples

      iex> new_forum(admin_actor)
      {:ok, %Ecto.Changeset{}}

  """
  @spec new_forum(Actor.t()) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban | :unauthorized}
  def new_forum(%Actor{} = actor) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, Forum) do
      {:ok, Forum.changeset(%Forum{}, %{})}
    end
  end

  @doc """
  Creates a forum on behalf of an authorized actor.

  ## Examples

      iex> create_forum(admin_actor, attrs)
      {:ok, %Forum{}}

      iex> create_forum(admin_actor, invalid_attrs)
      {:error, %Ecto.Changeset{}}

  """
  @spec create_forum(Actor.t(), map()) ::
          {:ok, Forum.t()} | {:error, :ban | :unauthorized | Ecto.Changeset.t()}
  def create_forum(%Actor{} = actor, attrs) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Forum) do
      insert_forum(attrs)
    end
  end

  @doc """
  Loads a forum edit form by short name.

  ## Examples

      iex> load_forum_for_edit(admin_actor, "dis")
      {:ok, {%Forum{}, %Ecto.Changeset{}}}

  """
  @spec load_forum_for_edit(Actor.t(), String.t()) ::
          {:ok, {Forum.t(), Ecto.Changeset.t()}} | {:error, :ban | :not_found | :unauthorized}
  def load_forum_for_edit(%Actor{} = actor, short_name) do
    with :ok <- verify_write_access(actor),
         {:ok, forum} <- load_authorized_forum(actor, :edit, short_name) do
      {:ok, {forum, Forum.changeset(forum, %{})}}
    end
  end

  @doc """
  Updates a forum selected by short name.

  ## Examples

      iex> update_forum(admin_actor, "dis", attrs)
      {:ok, %Forum{}}

  """
  @spec update_forum(Actor.t(), String.t(), map()) ::
          {:ok, Forum.t()} | {:error, :ban | :not_found | :unauthorized | Ecto.Changeset.t()}
  def update_forum(%Actor{} = actor, short_name, attrs) do
    with :ok <- verify_write_access(actor),
         {:ok, forum} <- load_authorized_forum(actor, :update, short_name) do
      persist_forum_update(forum, attrs)
    end
  end

  @doc """
  Returns the internal query used when topic or post changes recompute a forum's
  last visible post.

  ## Examples

      iex> update_forum_last_post_query(1)
      #Ecto.Query<...>

  """
  @spec update_forum_last_post_query(integer()) :: Ecto.Query.t()
  def update_forum_last_post_query(forum_id) do
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
end
