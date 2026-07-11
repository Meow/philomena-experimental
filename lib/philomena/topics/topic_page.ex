defmodule Philomena.Topics.TopicPage do
  @moduledoc """
  Assembled state for rendering a single forum topic view: the forum and topic
  being viewed, the current page of posts, the viewer's subscription and
  poll-vote state, whether the topic's poll is currently accepting votes, and the
  two changesets that drive the reply form and the title form.

  `posts` is a `Scrivener.Page` whose entries are raw `Post` structs: their
  bodies are rendered to HTML with the viewing user's filter by the web layer, so
  this struct never carries rendered Markdown.
  """

  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic

  @enforce_keys [
    :forum,
    :topic,
    :posts,
    :watching,
    :voted,
    :poll_active,
    :post_changeset,
    :topic_changeset
  ]

  defstruct @enforce_keys

  @type t :: %__MODULE__{
          forum: Forum.t(),
          topic: Topic.t(),
          posts: Scrivener.Page.t(),
          watching: boolean(),
          voted: boolean(),
          poll_active: boolean(),
          post_changeset: Ecto.Changeset.t(),
          topic_changeset: Ecto.Changeset.t()
        }
end
