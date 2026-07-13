defmodule Philomena.Forums do
  @moduledoc """
  The Forums context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic
  alias Philomena.Users.User

  use Philomena.Subscriptions,
    id_name: :forum_id

  @doc """
  Subscribes `actor` (the acting user) to the forum named by `forum_slug`.

  The forum is loaded by its short name and authorized for `:show`. Because an
  unknown short name loads `nil` and no ordinary rule permits `:show` on `nil`,
  a nonexistent forum comes back `{:error, :unauthorized}`.

  Returns `{:ok, forum}` (the forum is needed to render the subscription
  partial), `{:error, :unauthorized}` when the forum is not visible to the
  actor, or `{:error, %Ecto.Changeset{}}` if the subscription insert is
  rejected.

  ## Examples

      iex> subscribe(user, "dis")
      {:ok, %Forum{}}

      iex> subscribe(user, "nonexistent")
      {:error, :unauthorized}

  """
  @spec subscribe(User.t() | nil, String.t()) ::
          {:ok, Forum.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def subscribe(actor, forum_slug) do
    with {:ok, forum} <- load_forum(actor, forum_slug),
         {:ok, _subscription} <- create_subscription(forum, actor) do
      {:ok, forum}
    end
  end

  @doc """
  Unsubscribes `actor` (the acting user) from the forum named by `forum_slug`.

  Loading mirrors `subscribe/2`: the forum is loaded by short name and
  authorized for `:show`, so only the forum visibility check can fail.

  Returns `{:ok, forum}` or `{:error, :unauthorized}` when the forum is not
  visible to the actor.

  ## Examples

      iex> unsubscribe(user, "dis")
      {:ok, %Forum{}}

  """
  @spec unsubscribe(User.t() | nil, String.t()) ::
          {:ok, Forum.t()} | {:error, :unauthorized}
  def unsubscribe(actor, forum_slug) do
    with {:ok, forum} <- load_forum(actor, forum_slug) do
      # Deletion is idempotent and cannot fail; the hard match crashes if it does.
      {:ok, _subscription} = delete_subscription(forum, actor)
      {:ok, forum}
    end
  end

  # The forum is loaded by short name and authorized for `:show`. An unknown
  # forum authorizes `nil`, which no ordinary rule permits, so it is
  # unauthorized; the admin blanket rule authorizes `nil` and the nil forum then
  # flows into the subscription helper unchanged.
  defp load_forum(actor, forum_slug) do
    forum = Repo.get_by(Forum, short_name: to_string(forum_slug))

    with :ok <- authorize(actor, :show, forum) do
      {:ok, forum}
    end
  end

  @doc """
  Returns the list of forums.

  ## Examples

      iex> list_forums()
      [%Forum{}, ...]

  """
  def list_forums do
    Repo.all(Forum)
  end

  @doc """
  Gets a single forum.

  Raises `Ecto.NoResultsError` if the Forum does not exist.

  ## Examples

      iex> get_forum!(123)
      %Forum{}

      iex> get_forum!(456)
      ** (Ecto.NoResultsError)

  """
  def get_forum!(id), do: Repo.get!(Forum, id)

  @doc """
  Assembles the forum index for `user`.

  Returns `{forums, topic_count}`: every forum `user` may `:show`, ordered by
  name with each forum's last post preloaded, and the total topic count summed
  across all forums.
  """
  @spec load_forum_index(User.t() | nil) :: {[Forum.t()], integer() | nil}
  def load_forum_index(user) do
    forums =
      Forum
      |> order_by(asc: :name)
      |> preload(last_post: [:user, topic: :forum])
      |> Repo.all()
      |> Enum.filter(&(authorize(user, :show, &1) == :ok))

    topic_count = Repo.aggregate(Forum, :sum, :topic_count)

    {forums, topic_count}
  end

  @doc """
  Assembles the forum show page named by `short_name` for `user`.

  The forum is loaded by its short name and authorized for `:show`, so an
  unknown or restricted forum is `{:error, :unauthorized}`. On success returns
  `{:ok, {forum, topics, watching}}`: the forum, its visible topics paginated
  with `pagination` (ordered sticky first, then most recently replied to), and
  whether `user` subscribes to the forum.
  """
  @spec load_forum_show(User.t() | nil, String.t(), map()) ::
          {:ok, {Forum.t(), Scrivener.Page.t(), boolean()}} | {:error, :unauthorized}
  def load_forum_show(user, short_name, pagination) do
    forum = Repo.get_by(Forum, short_name: short_name)

    with :ok <- authorize(user, :show, forum) do
      topics =
        Topic
        |> where(forum_id: ^forum.id)
        |> where(hidden_from_users: false)
        |> order_by(desc: :sticky, desc: :last_replied_to_at)
        |> preload([:poll, :forum, :user, last_post: :user])
        |> Repo.paginate(pagination)

      {:ok, {forum, topics, subscribed?(forum, user)}}
    end
  end

  @doc """
  Lists the forums exposed by the public API, paginated with `pagination`.

  Only forums whose access level is `"normal"` are returned, for every
  requester alike; restricted forums are never listed here. Results are ordered
  by name.

  Returns a `Scrivener.Page` of forums.

  ## Examples

      iex> api_list_forums(pagination)
      %Scrivener.Page{}

  """
  @spec api_list_forums(map()) :: Scrivener.Page.t()
  def api_list_forums(pagination) do
    Forum
    |> where(access_level: "normal")
    |> order_by(asc: :name)
    |> Repo.paginate(pagination)
  end

  @doc """
  Fetches a single forum for the public API by its `short_name`.

  Only a forum whose access level is `"normal"` is returned, for every requester
  alike; a restricted or nonexistent forum is reported as missing.

  Returns `{:ok, forum}` or `{:error, :not_found}`.

  ## Examples

      iex> api_show_forum("dis")
      {:ok, %Forum{}}

      iex> api_show_forum("staff")
      {:error, :not_found}

  """
  @spec api_show_forum(String.t()) :: {:ok, Forum.t()} | {:error, :not_found}
  def api_show_forum(short_name) do
    Forum
    |> where(short_name: ^short_name)
    |> where(access_level: "normal")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      forum -> {:ok, forum}
    end
  end

  @doc """
  Creates a forum.

  ## Examples

      iex> create_forum(%{field: value})
      {:ok, %Forum{}}

      iex> create_forum(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_forum(attrs \\ %{}) do
    %Forum{}
    |> Forum.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Authorizes `actor` to manage forums through the admin interface.

  Forum administration is admin-only (`:edit` on the forum model). Returns `:ok`
  or `{:error, :unauthorized}`; gates the admin listing, which renders the forum
  list assembled by the request pipeline.
  """
  @spec authorize_admin(User.t() | nil) :: :ok | {:error, :unauthorized}
  def authorize_admin(actor) do
    authorize(actor, :edit, Forum)
  end

  @doc """
  Builds the changeset backing the new-forum form, on behalf of `actor`.

  Authorizes forum administration. Returns `{:ok, changeset}` or
  `{:error, :unauthorized}`.
  """
  @spec new_forum(User.t() | nil) :: {:ok, Ecto.Changeset.t()} | {:error, :unauthorized}
  def new_forum(actor) do
    with :ok <- authorize_admin(actor) do
      {:ok, change_forum(%Forum{})}
    end
  end

  @doc """
  Creates a forum on behalf of `actor`.

  Authorizes forum administration, then inserts the forum through
  `create_forum/1`. Returns `{:ok, forum}`, `{:error, :unauthorized}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec create_forum(User.t() | nil, map()) ::
          {:ok, Forum.t()} | {:error, :unauthorized | Ecto.Changeset.t()}
  def create_forum(actor, attrs) do
    with :ok <- authorize_admin(actor) do
      create_forum(attrs)
    end
  end

  @doc """
  Loads the forum named by `short_name` for editing, on behalf of `actor`,
  pairing it with the changeset backing the edit form.

  Authorizes forum administration, then loads the forum by its short name.
  Returns `{:ok, {forum, changeset}}`, `{:error, :unauthorized}`, or
  `{:error, :not_found}` for an unknown short name.
  """
  @spec load_forum_for_edit(User.t() | nil, any()) ::
          {:ok, {Forum.t(), Ecto.Changeset.t()}} | {:error, :unauthorized | :not_found}
  def load_forum_for_edit(actor, short_name) do
    with :ok <- authorize_admin(actor),
         {:ok, forum} <- fetch_forum(short_name) do
      {:ok, {forum, change_forum(forum)}}
    end
  end

  @doc """
  Updates the forum named by `short_name`, on behalf of `actor`.

  Authorizes forum administration, loads the forum by its short name, then
  applies the update through `update_forum/2`. Returns `{:ok, forum}`,
  `{:error, :unauthorized}`, `{:error, :not_found}`, or
  `{:error, %Ecto.Changeset{}}`.
  """
  @spec update_forum(User.t() | nil, any(), map()) ::
          {:ok, Forum.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update_forum(actor, short_name, attrs) do
    with :ok <- authorize_admin(actor),
         {:ok, forum} <- fetch_forum(short_name) do
      update_forum(forum, attrs)
    end
  end

  defp fetch_forum(short_name) do
    case Repo.get_by(Forum, short_name: to_string(short_name)) do
      nil -> {:error, :not_found}
      forum -> {:ok, forum}
    end
  end

  @doc """
  Updates a forum.

  ## Examples

      iex> update_forum(forum, %{field: new_value})
      {:ok, %Forum{}}

      iex> update_forum(forum, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_forum(%Forum{} = forum, attrs) do
    forum
    |> Forum.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Forum.

  ## Examples

      iex> delete_forum(forum)
      {:ok, %Forum{}}

      iex> delete_forum(forum)
      {:error, %Ecto.Changeset{}}

  """
  def delete_forum(%Forum{} = forum) do
    Repo.delete(forum)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking forum changes.

  ## Examples

      iex> change_forum(forum)
      %Ecto.Changeset{source: %Forum{}}

  """
  def change_forum(%Forum{} = forum) do
    Forum.changeset(forum, %{})
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
