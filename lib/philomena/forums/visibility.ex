defmodule Philomena.Forums.Visibility do
  @moduledoc """
  Database query scopes for forum hierarchy collection reads.

  These scopes intentionally mirror the `:show` rules in
  `Philomena.Users.Ability`. Collection endpoints use them before counting and
  pagination so authorization cost is bounded by the requested page.
  """

  import Ecto.Query, warn: false

  alias Philomena.Attribution.Actor
  alias Philomena.Users.User

  @doc """
  Restricts a forum query to the access levels visible to `actor`.

  ## Examples

      iex> visible_forums(Forum, actor)
      #Ecto.Query<...>

  """
  @spec visible_forums(Ecto.Queryable.t(), Actor.t()) :: Ecto.Query.t()
  def visible_forums(queryable, %Actor{user: %User{role: role}})
      when role in ["admin", "moderator"],
      do: from(forum in queryable)

  def visible_forums(queryable, %Actor{user: %User{role: "assistant"}}),
    do: from(forum in queryable, where: forum.access_level in ["normal", "assistant"])

  def visible_forums(queryable, %Actor{}),
    do: from(forum in queryable, where: forum.access_level == "normal")

  @doc """
  Restricts a topic query to topics visible to `actor`.

  The caller remains responsible for constraining the query to authorized
  parent forums.

  ## Examples

      iex> visible_topics(Topic, actor)
      #Ecto.Query<...>

  """
  @spec visible_topics(Ecto.Queryable.t(), Actor.t()) :: Ecto.Query.t()
  def visible_topics(queryable, %Actor{user: %User{role: role}})
      when role in ["admin", "moderator", "assistant"],
      do: from(topic in queryable)

  def visible_topics(queryable, %Actor{}),
    do: from(topic in queryable, where: topic.hidden_from_users == false)

  @doc """
  Restricts a post query to posts visible to `actor`.

  Moderators, administrators, and topic-moderator assistants may see hidden
  posts. The caller remains responsible for constraining and authorizing the
  parent forum and topic.

  ## Examples

      iex> visible_posts(Post, actor)
      #Ecto.Query<...>

  """
  @spec visible_posts(Ecto.Queryable.t(), Actor.t()) :: Ecto.Query.t()
  def visible_posts(queryable, %Actor{user: %User{role: role}})
      when role in ["admin", "moderator"],
      do: from(post in queryable)

  def visible_posts(
        queryable,
        %Actor{user: %User{role: "assistant", role_map: %{"Topic" => %{"moderator" => _}}}}
      ),
      do: from(post in queryable)

  def visible_posts(queryable, %Actor{}),
    do: from(post in queryable, where: post.hidden_from_users == false)

  @doc """
  Generates an OpenSearch boolean `filter` clause to select posts visible to `actor`.

  Moderators, administrators, and topic moderator assistants may see hidden
  posts.

  ## Examples

      iex> search_filters(admin_actor)
      []

      iex> search_filters(actor)
      [%{term: %{access_level: "normal"}}, ...]

  """
  @spec search_filters(Actor.t()) :: list()
  def search_filters(actor)

  def search_filters(%Actor{user: %User{role: role}})
      when role in ["moderator", "admin"],
      do: []

  def search_filters(%Actor{user: %User{role: "assistant"}}) do
    [%{terms: %{access_level: ["normal", "assistant"]}}]
  end

  def search_filters(%Actor{}) do
    [
      %{term: %{access_level: "normal"}},
      %{term: %{hidden_from_users: false}}
    ]
  end
end
