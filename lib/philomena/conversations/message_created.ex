defmodule Philomena.Conversations.MessageCreated do
  @moduledoc """
  The result of posting a conversation message, including the total needed to
  compute the redirect page.
  """

  alias Philomena.Conversations.Conversation
  alias Philomena.Conversations.Message

  @enforce_keys [:conversation, :message, :message_count]
  defstruct [:conversation, :message, :message_count]

  @type t :: %__MODULE__{
          conversation: Conversation.t(),
          message: Message.t(),
          message_count: non_neg_integer()
        }
end
