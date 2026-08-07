defmodule Philomena.Conversations.ConversationForm do
  @moduledoc """
  A new conversation and the changeset rendered by its form.
  """

  alias Philomena.Conversations.Conversation

  @enforce_keys [:conversation, :changeset]
  defstruct [:conversation, :changeset]

  @type t :: %__MODULE__{
          conversation: Conversation.t(),
          changeset: Ecto.Changeset.t()
        }
end
