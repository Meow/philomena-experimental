defmodule Philomena.Polls.TopicPoll do
  @moduledoc """
  A poll paired with the forum and topic that constrained its lookup.
  """

  alias Philomena.Forums.Forum
  alias Philomena.Polls.Poll
  alias Philomena.Topics.Topic

  @enforce_keys [:forum, :topic, :poll]
  defstruct @enforce_keys

  @type t :: %__MODULE__{forum: Forum.t(), topic: Topic.t(), poll: Poll.t()}
end
