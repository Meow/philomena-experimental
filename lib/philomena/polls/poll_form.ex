defmodule Philomena.Polls.PollForm do
  @moduledoc """
  A parent-scoped poll edit form.
  """

  alias Philomena.Forums.Forum
  alias Philomena.Polls.Poll
  alias Philomena.Topics.Topic

  @enforce_keys [:forum, :topic, :poll, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          forum: Forum.t(),
          topic: Topic.t(),
          poll: Poll.t(),
          changeset: Ecto.Changeset.t()
        }
end
