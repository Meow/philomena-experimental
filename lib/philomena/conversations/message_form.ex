defmodule Philomena.Conversations.MessageForm do
  @moduledoc """
  A loaded conversation, attempted reply, and message changeset returned
  after reply validation fails.
  """

  alias Philomena.Conversations.Conversation
  alias Philomena.Conversations.Message

  @enforce_keys [:conversation, :message, :changeset]
  defstruct [:conversation, :message, :changeset]

  @type t :: %__MODULE__{
          conversation: Conversation.t(),
          message: Message.t(),
          changeset: Ecto.Changeset.t()
        }
end
