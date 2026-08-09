defmodule Philomena.Topics.ForumTopic do
  @moduledoc """
  A topic paired with the forum that constrained its lookup.

  Contexts use this result to retain proof of route ancestry while passing the
  pair through deeper post and poll loaders.
  """

  alias Philomena.Forums.Forum
  alias Philomena.Topics.Topic

  @enforce_keys [:forum, :topic]
  defstruct @enforce_keys

  @type t :: %__MODULE__{forum: Forum.t(), topic: Topic.t()}
end
