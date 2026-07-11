defmodule Philomena.Forums do
  @moduledoc """
  The Forums context.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3]

  alias Philomena.Repo

  alias Philomena.Forums.Forum
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
