defmodule Philomena.Forums do
  @moduledoc """
  The Forums context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Attribution.Actor
  alias Philomena.Repo

  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic

  use Philomena.Subscriptions,
    id_name: :forum_id

  # Creates a forum. Visible for testing.
  @doc false
  def create_forum(attrs \\ %{}) do
    %Forum{}
    |> Forum.changeset(attrs)
    |> Repo.insert()
  end

  # Updates a forum.
  defp update_forum(%Forum{} = forum, attrs) do
    forum
    |> Forum.changeset(attrs)
    |> Repo.update()
  end

  # Returns an `%Ecto.Changeset{}` for tracking forum changes.
  defp change_forum(%Forum{} = forum) do
    Forum.changeset(forum, %{})
  end

  @doc """
  Subscribes `actor` to the forum named by `short_name`.

  The forum is loaded by its short name and authorized for `:show`.

  ## Examples

      iex> subscribe(user, "dis")
      {:ok, %Forum{}}

      iex> subscribe(user, "nonexistent")
      {:error, :unauthorized}

  """
  @spec subscribe(Actor.t(), String.t()) ::
          {:ok, Forum.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def subscribe(%Actor{} = actor, short_name) do
    with {:ok, forum} <- load_forum(actor, short_name),
         {:ok, _subscription} <- create_subscription(forum, actor.user) do
      {:ok, forum}
    end
  end

  @doc """
  Unsubscribes `actor` from the forum named by `short_name`.

  ## Examples

      iex> unsubscribe(user, "dis")
      {:ok, %Forum{}}

      iex> unsubscribe(user, "staff")
      {:error, :unauthorized}

  """
  @spec unsubscribe(Actor.t(), String.t()) ::
          {:ok, Forum.t()} | {:error, :unauthorized}
  def unsubscribe(%Actor{} = actor, short_name) do
    with {:ok, forum} <- load_forum(actor, short_name) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(forum, actor.user)
      {:ok, forum}
    end
  end

  # The forum is loaded by short name and authorized for `:show`. An unknown
  # forum authorizes `nil`, which no ordinary rule permits, so it is
  # unauthorized; the admin blanket rule authorizes `nil` and the nil forum then
  # flows into the subscription helper unchanged.
  defp load_forum(actor, short_name) do
    forum = Repo.get_by(Forum, short_name: to_string(short_name))

    with :ok <- authorize(actor, :show, forum) do
      {:ok, forum}
    end
  end

  defp fetch_forum(short_name) do
    # TODO: shouldn't this be folded into the above function?
    case Repo.get_by(Forum, short_name: to_string(short_name)) do
      nil -> {:error, :not_found}
      forum -> {:ok, forum}
    end
  end

  @doc """
  Assembles the forum index for `actor`.

  Returns `{forums, topic_count}`: every forum `actor` may `:show`, ordered by
  name with each forum's last post preloaded, and the total topic count summed
  across all forums.

  ## Examples

      iex> load_forum_index(user)
      {[%Forum{}, ...], 1234}

  """
  @spec load_forum_index(Actor.t()) :: {[Forum.t()], integer() | nil}
  def load_forum_index(%Actor{} = actor) do
    forums =
      Forum
      |> order_by(asc: :name)
      |> preload(last_post: [:user, topic: :forum])
      |> Repo.all()
      |> Enum.filter(&(authorize(actor, :show, &1) == :ok))

    # FIXME: shouldn't it be the topic count of forums visible to the actor?
    topic_count = Repo.aggregate(Forum, :sum, :topic_count)

    {forums, topic_count}
  end

  @doc """
  Assembles the forum named by `short_name` and its topics for `actor`.

  The forum is loaded by its short name and authorized for `:show`. On success,
  returns `{:ok, {forum, topics, watching}}`: the forum, its visible topics
  paginated with `pagination` (ordered sticky first, then most recently replied to),
  and whether `actor` subscribes to the forum.

  ## Examples

      iex> load_forum_show(user, "dis", pagination)
      {:ok, {%Forum{}, %Scrivener.Page{}, false}}

      iex> load_forum_show(user, "staff", pagination)
      {:error, :unauthorized}

  """
  @spec load_forum_show(Actor.t(), String.t(), Repo.pagination_params()) ::
          {:ok, {Forum.t(), Scrivener.Page.t(Topic.t()), boolean()}} | {:error, :unauthorized}
  def load_forum_show(%Actor{} = actor, short_name, pagination) do
    forum = Repo.get_by(Forum, short_name: short_name)

    with :ok <- authorize(actor, :show, forum) do
      topics =
        Topic
        |> where(forum_id: ^forum.id)
        |> where(hidden_from_users: false)
        |> order_by(desc: :sticky, desc: :last_replied_to_at)
        |> preload([:poll, :forum, :user, last_post: :user])
        |> Repo.paginate(pagination)

      {:ok, {forum, topics, subscribed?(forum, actor.user)}}
    end
  end

  @doc """
  Lists publicly accessible forums, paginated with `pagination`.

  Only forums whose access level is `"normal"` are returned.

  ## Examples

      iex> list_public_forums(pagination)
      %Scrivener.Page{}

  """
  @spec list_public_forums(Repo.pagination_params()) :: Scrivener.Page.t(Forum.t())
  def list_public_forums(pagination) do
    # TODO: get rid of this and use load_forum_index
    Forum
    |> where(access_level: "normal")
    |> order_by(asc: :name)
    |> Repo.paginate(pagination)
  end

  @doc """
  Fetches a single publicly accessible forum by its `short_name`.

  Only a forum whose access level is `"normal"` is returned.

  Returns `{:ok, forum}` or `{:error, :not_found}`.

  ## Examples

      iex> load_public_forum("dis")
      {:ok, %Forum{}}

      iex> load_public_forum("staff")
      {:error, :not_found}

  """
  @spec load_public_forum(String.t()) :: {:ok, Forum.t()} | {:error, :not_found}
  def load_public_forum(short_name) do
    # TODO: get rid of this and use load_forum_show
    Forum
    |> where(short_name: ^short_name)
    |> where(access_level: "normal")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      forum -> {:ok, forum}
    end
  end

  # Authorizes `actor` to manage forums.
  # FIXME: this function shouldn't be public and the controller is wrong to directly depend on it
  @doc false
  @spec authorize_admin(Actor.t()) :: :ok | {:error, :unauthorized}
  def authorize_admin(%Actor{} = actor) do
    authorize(actor, :edit, Forum)
  end

  @doc """
  Builds a changeset for creating a new forum, on behalf of `actor`.

  ## Examples

      iex> new_forum(admin)
      {:ok, %Ecto.Changeset{}}

      iex> new_forum(user)
      {:error, :unauthorized}

  """
  @spec new_forum(Actor.t()) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_forum(%Actor{} = actor) do
    with :ok <- authorize_admin(actor) do
      {:ok, change_forum(%Forum{})}
    end
  end

  @doc """
  Creates a forum on behalf of `actor`.

  ## Examples

      iex> create_forum(admin, forum_params)
      {:ok, %Forum{}}

      iex> create_forum(admin, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> create_forum(user, forum_params)
      {:error, :unauthorized}

  """
  @spec create_forum(Actor.t(), map()) ::
          {:ok, Forum.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_forum(%Actor{} = actor, attrs) do
    with :ok <- authorize_admin(actor) do
      create_forum(attrs)
    end
  end

  @doc """
  Loads the forum named by `short_name` for editing, on behalf of `actor`,
  pairing it with a change-tracking changeset for it.

  Authorizes forum administration, then loads the forum by its short name.
  Returns `{:ok, {forum, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}` for an unknown short name.

  ## Examples

      iex> load_forum_for_edit(admin, short_name)
      {:ok, {%Forum{}, %Ecto.Changeset{}}}

      iex> load_forum_for_edit(admin, invalid_name)
      {:error, :not_found}

      iex> load_forum_for_edit(user, short_name)
      {:error, :unauthorized}

  """
  @spec load_forum_for_edit(Actor.t(), String.t()) ::
          {:ok, {Forum.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_forum_for_edit(%Actor{} = actor, short_name) do
    with :ok <- authorize_admin(actor),
         {:ok, forum} <- fetch_forum(short_name) do
      {:ok, {forum, change_forum(forum)}}
    end
  end

  @doc """
  Updates the forum named by `short_name`, on behalf of `actor`.

  ## Examples

      iex> update_forum(admin, short_name, forum_params)
      {:ok, %Forum{}}

      iex> update_forum(admin, short_name, invalid_params)
      {:error, %Ecto.Changeset{}}

      iex> update_forum(admin, invalid_name, forum_params)
      {:error, :not_found}

      iex> update_forum(user, short_name, forum_params)
      {:error, :unauthorized}

  """
  @spec update_forum(Actor.t(), String.t(), map()) ::
          {:ok, Forum.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_forum(%Actor{} = actor, short_name, attrs) do
    with :ok <- authorize_admin(actor),
         {:ok, forum} <- fetch_forum(short_name) do
      update_forum(forum, attrs)
    end
  end

  @doc """
  Returns an `m:Ecto.Query` which updates the last post for the given forum.

  ## Examples

      iex> update_forum_last_post_query(1)
      #Ecto.Query<...>

  """
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
