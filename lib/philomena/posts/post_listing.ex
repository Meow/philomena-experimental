defmodule Philomena.Posts.PostListing do
  @moduledoc """
  A parent-scoped forum topic and its paginated actor-visible posts.
  """

  alias Philomena.Forums.Forum
  alias Philomena.Posts.Post
  alias Philomena.Topics.Topic

  @enforce_keys [:forum, :topic, :posts]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          forum: Forum.t(),
          topic: Topic.t(),
          posts: Scrivener.Page.t(Post.t())
        }
end
