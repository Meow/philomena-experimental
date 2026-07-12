defmodule Philomena.Conversations.ConversationPage do
  @moduledoc """
  Assembled data backing the conversation show page: the conversation, a
  `m:Scrivener.Page` of its raw messages, and the changeset for the reply form.

  Message bodies are carried unrendered; the web layer renders their Markdown.
  """

  alias Philomena.Conversations.Conversation

  @enforce_keys [:conversation, :messages, :changeset]
  defstruct [:conversation, :messages, :changeset]

  @type t :: %__MODULE__{
          conversation: Conversation.t(),
          messages: Scrivener.Page.t(),
          changeset: Ecto.Changeset.t()
        }
end
