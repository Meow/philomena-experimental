defmodule Philomena.Conversations do
  @moduledoc """
  The Conversations context.
  """

  import Ecto.Query, warn: false

  import Philomena.Authorization,
    only: [authorize: 3, verify_write_access: 1, verify_not_banned: 1]

  alias Ecto.Multi
  alias Philomena.Repo
  alias Philomena.Attribution.Actor
  alias Philomena.Conversations.Conversation
  alias Philomena.Conversations.ConversationPage
  alias Philomena.Conversations.Message
  alias Philomena.IntegerId
  alias Philomena.ModerationLogs
  alias Philomena.Reports
  alias Philomena.Users
  alias Philomena.Users.User

  @doc """
  Returns the number of unread conversations for the given user.

  Conversations hidden by the given user are not counted.

  ## Examples

      iex> count_unread_conversations(user1)
      0

      iex> count_unread_conversations(user2)
      7

  """
  def count_unread_conversations(user) do
    Conversation
    |> where(
      [c],
      ((c.to_id == ^user.id and c.to_read == false) or
         (c.from_id == ^user.id and c.from_read == false)) and
        not ((c.to_id == ^user.id and c.to_hidden == true) or
               (c.from_id == ^user.id and c.from_hidden == true))
    )
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns a `m:Scrivener.Page` of the conversations `user` participates in, on
  their own behalf.

  Conversations `user` has hidden are excluded. When `params` carries a
  `"with"` key, the list is restricted to conversations exchanged with that
  partner id; otherwise every conversation involving `user` is listed, newest
  message first. The `"with"` value is compared against the id column directly,
  so a non-numeric value raises `Ecto.Query.CastError`.

  ## Examples

      iex> list_conversations(%User{}, %{}, page_size: 10)
      %Scrivener.Page{}

      iex> list_conversations(%User{}, %{"with" => "123"}, page_size: 10)
      %Scrivener.Page{}

  """
  @spec list_conversations(User.t(), map(), keyword()) :: Scrivener.Page.t()
  def list_conversations(user, params, pagination) do
    case params do
      %{"with" => partner_id} ->
        query =
          from c in Conversation,
            where:
              (c.from_id == ^partner_id and c.to_id == ^user.id) or
                (c.to_id == ^partner_id and c.from_id == ^user.id)

        paginate_conversations(query, user, pagination)

      _ ->
        paginate_conversations(Conversation, user, pagination)
    end
  end

  defp paginate_conversations(queryable, user, pagination) do
    query =
      from c in queryable,
        as: :conversations,
        where:
          (c.from_id == ^user.id and not c.from_hidden) or
            (c.to_id == ^user.id and not c.to_hidden),
        inner_lateral_join:
          cnt in subquery(
            from m in Message,
              where: m.conversation_id == parent_as(:conversations).id,
              select: %{count: count()}
          ),
        on: true,
        order_by: [desc: :last_message_at],
        preload: [:to, :from],
        select: %{c | message_count: cnt.count}

    Repo.paginate(query, pagination)
  end

  @doc """
  Loads the conversation named by `slug` for its show page, on behalf of `user`.

  The conversation is loaded with both participants and authorized for `:show`
  (participants, moderators, and admins); an unknown slug authorizes `nil`,
  which no ordinary rule permits, so it is `{:error, :unauthorized}`
  (`{:error, :not_found}` for admins). `user`'s side of the conversation is
  marked read as a side effect. The returned page carries a `m:Scrivener.Page`
  of the raw messages, ordered by `user`'s `messages_newest_first` preference,
  and the reply-form changeset; message Markdown is rendered by the caller.

  ## Examples

      iex> load_conversation_page(%User{}, "slug", page_size: 25)
      {:ok, %ConversationPage{}}

  """
  @spec load_conversation_page(User.t(), String.t(), keyword()) ::
          {:ok, ConversationPage.t()} | {:error, :unauthorized | :not_found}
  def load_conversation_page(user, slug, pagination) do
    with {:ok, conversation} <- load_authorized_conversation(user, slug, [:to, :from]) do
      messages = paginate_messages(conversation, user, pagination)
      {:ok, _conversation} = mark_conversation_read(conversation, user)

      page = %ConversationPage{
        conversation: conversation,
        messages: messages,
        changeset: change_message(%Message{})
      }

      {:ok, page}
    end
  end

  defp paginate_messages(conversation, user, pagination) do
    direction =
      if user.messages_newest_first do
        :desc
      else
        :asc
      end

    Message
    |> where(conversation_id: ^conversation.id)
    |> order_by([{^direction, :created_at}])
    |> preload(:from)
    |> Repo.paginate(pagination)
  end

  # Loads a conversation by slug and authorizes it for `:show`. A slug naming no
  # row authorizes `nil`: no ordinary rule permits it, so regular users get
  # `{:error, :unauthorized}`, while an admin's blanket grant lets `nil` through
  # to `{:error, :not_found}`.
  defp load_authorized_conversation(user, slug, preloads \\ []) do
    conversation =
      Conversation
      |> where(slug: ^slug)
      |> preload(^preloads)
      |> Repo.one()

    with :ok <- authorize(user, :show, conversation),
         %Conversation{} <- conversation do
      {:ok, conversation}
    else
      {:error, :unauthorized} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Loads the changeset backing the new-conversation form, on behalf of `actor`.

  This is a GET-guarded action, so a banned actor is rejected with
  `{:error, :ban}`; the changeset otherwise pre-fills the given `recipient`.

  ## Examples

      iex> load_new_conversation(actor, "recipient-name")
      {:ok, %Ecto.Changeset{}}

  """
  @spec load_new_conversation(Actor.t(), String.t() | nil) ::
          {:ok, Ecto.Changeset.t()} | {:error, :ban}
  def load_new_conversation(%Actor{} = actor, recipient) do
    with :ok <- verify_not_banned(actor) do
      changeset = change_conversation(%Conversation{recipient: recipient, messages: [%Message{}]})
      {:ok, changeset}
    end
  end

  @doc """
  Creates a conversation sent by `actor`, from controller-shaped `params`.

  This is a write, so `actor`'s write access is verified first: a banned actor
  is `{:error, :ban}` and an actor with no fingerprint `{:error, :unauthorized}`.
  The recipient is resolved from the `"recipient"` param; a system report is
  filed against the first message when it is withheld from approval.

  Returns `{:ok, conversation}` on success or `{:error, %Ecto.Changeset{}}` when
  the insert is rejected (an unknown recipient fails the required-recipient
  validation).

  ## Examples

      iex> create_conversation(actor, %{"recipient" => "name", "title" => "Hi"})
      {:ok, %Conversation{}}

      iex> create_conversation(actor, %{"recipient" => "nobody"})
      {:error, %Ecto.Changeset{}}

  """
  @spec create_conversation(Actor.t(), map() | nil) ::
          {:ok, Conversation.t()} | {:error, :ban | :unauthorized} | {:error, Ecto.Changeset.t()}
  def create_conversation(%Actor{} = actor, params) do
    with :ok <- verify_write_access(actor) do
      create_conversation_from(actor.user, params || %{})
    end
  end

  @doc """
  Creates a conversation with `from` as the sender.

  ## Examples

      iex> create_conversation_from(from, %{field: value})
      {:ok, %Conversation{}}

      iex> create_conversation_from(from, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_conversation_from(from, attrs \\ %{}) do
    to = Users.get_user_by_name(attrs["recipient"])

    %Conversation{}
    |> Conversation.creation_changeset(from, to, attrs)
    |> Repo.insert()
    |> case do
      {:ok, conversation} ->
        report_non_approved_message(hd(conversation.messages))
        {:ok, conversation}

      error ->
        error
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking conversation changes.

  ## Examples

      iex> change_conversation(conversation)
      %Ecto.Changeset{source: %Conversation{}}

  """
  def change_conversation(%Conversation{} = conversation) do
    Conversation.changeset(conversation, %{})
  end

  @doc """
  Marks a conversation as read or unread from the perspective of the given user.

  ## Examples

      iex> mark_conversation_read(conversation, user, true)
      {:ok, %Conversation{}}

      iex> mark_conversation_read(conversation, user, false)
      {:ok, %Conversation{}}

      iex> mark_conversation_read(conversation, %User{}, true)
      {:error, %Ecto.Changeset{}}

  """
  def mark_conversation_read(%Conversation{} = conversation, user, read \\ true) do
    changes =
      %{}
      |> put_conditional(:to_read, read, conversation.to_id == user.id)
      |> put_conditional(:from_read, read, conversation.from_id == user.id)

    conversation
    |> Conversation.read_changeset(changes)
    |> Repo.update()
  end

  @doc """
  Marks a conversation as hidden or visible from the perspective of the given user.

  Hidden conversations are not shown in the list of conversations for the user, and
  are not counted when retrieving the number of unread conversations.

  ## Examples

      iex> mark_conversation_hidden(conversation, user, true)
      {:ok, %Conversation{}}

      iex> mark_conversation_hidden(conversation, user, false)
      {:ok, %Conversation{}}

      iex> mark_conversation_hidden(conversation, %User{}, true)
      {:error, %Ecto.Changeset{}}

  """
  def mark_conversation_hidden(%Conversation{} = conversation, user, hidden \\ true) do
    changes =
      %{}
      |> put_conditional(:to_hidden, hidden, conversation.to_id == user.id)
      |> put_conditional(:from_hidden, hidden, conversation.from_id == user.id)

    conversation
    |> Conversation.hidden_changeset(changes)
    |> Repo.update()
  end

  @doc """
  Marks the conversation named by `slug` as read (`read: true`) or unread
  (`read: false`) for `user`, on their own behalf.

  The conversation is authorized for `:show` first; an unknown slug or a
  conversation `user` may not view is `{:error, :unauthorized}` (an admin's
  blanket grant turns an unknown slug into `{:error, :not_found}`). The read
  flag is set only for `user`'s own side, so a moderator viewing a conversation
  they are not part of succeeds without changing either flag.

  Returns `{:ok, conversation}` for the redirect target.

  ## Examples

      iex> set_conversation_read(%User{}, "slug")
      {:ok, %Conversation{}}

      iex> set_conversation_read(%User{}, "slug", false)
      {:ok, %Conversation{}}

  """
  @spec set_conversation_read(User.t(), String.t(), boolean()) ::
          {:ok, Conversation.t()} | {:error, :unauthorized | :not_found}
  def set_conversation_read(user, slug, read \\ true) do
    with {:ok, conversation} <- load_authorized_conversation(user, slug) do
      {:ok, _conversation} = mark_conversation_read(conversation, user, read)
      {:ok, conversation}
    end
  end

  @doc """
  Marks the conversation named by `slug` as hidden (`hidden: true`) or restored
  (`hidden: false`) for `user`, on their own behalf.

  The conversation is authorized for `:show` first; an unknown slug or a
  conversation `user` may not view is `{:error, :unauthorized}` (an admin's
  blanket grant turns an unknown slug into `{:error, :not_found}`). The hidden
  flag is set only for `user`'s own side.

  Returns `{:ok, conversation}` for the redirect target.

  ## Examples

      iex> set_conversation_hidden(%User{}, "slug")
      {:ok, %Conversation{}}

      iex> set_conversation_hidden(%User{}, "slug", false)
      {:ok, %Conversation{}}

  """
  @spec set_conversation_hidden(User.t(), String.t(), boolean()) ::
          {:ok, Conversation.t()} | {:error, :unauthorized | :not_found}
  def set_conversation_hidden(user, slug, hidden \\ true) do
    with {:ok, conversation} <- load_authorized_conversation(user, slug) do
      {:ok, _conversation} = mark_conversation_hidden(conversation, user, hidden)
      {:ok, conversation}
    end
  end

  defp put_conditional(map, key, value, condition) do
    if condition do
      Map.put(map, key, value)
    else
      map
    end
  end

  @doc """
  Returns the number of messages in the given conversation.

  ## Example

      iex> count_messages(%Conversation{})
      3

  """
  def count_messages(conversation) do
    Message
    |> where(conversation_id: ^conversation.id)
    |> Repo.aggregate(:count)
  end

  @doc """
  Posts a message to the conversation named by `slug`, sent by `actor`.

  This is a write, so `actor`'s write access is verified first: a banned actor
  is `{:error, :ban}` and an actor with no fingerprint `{:error, :unauthorized}`.
  The conversation is then authorized for `:show`; an unknown slug or a
  conversation the actor may not view is `{:error, :unauthorized}` (an admin's
  blanket grant turns an unknown slug into `{:error, :not_found}`).

  On success the message is inserted, both sides of the conversation are marked
  unread, and a system report is filed when the message is withheld from
  approval. Returns `{:ok, {conversation, message}}` so the caller can compute
  the last-page redirect. A rejected insert (e.g. a blank body) is
  `{:error, {:message_failed, conversation}}`, carrying the conversation for the
  error redirect.

  ## Examples

      iex> create_message(actor, "slug", %{"body" => "hello"})
      {:ok, {%Conversation{}, %Message{}}}

      iex> create_message(actor, "slug", %{"body" => ""})
      {:error, {:message_failed, %Conversation{}}}

  """
  @spec create_message(Actor.t(), String.t(), map() | nil) ::
          {:ok, {Conversation.t(), Message.t()}}
          | {:error, :ban | :unauthorized | :not_found}
          | {:error, {:message_failed, Conversation.t()}}
  def create_message(%Actor{} = actor, slug, params) do
    with :ok <- verify_write_access(actor),
         {:ok, conversation} <- load_authorized_conversation(actor.user, slug) do
      case create_conversation_message(conversation, actor.user, params || %{}) do
        {:ok, message} -> {:ok, {conversation, message}}
        {:error, _changeset} -> {:error, {:message_failed, conversation}}
      end
    end
  end

  @doc """
  Creates a message within a conversation, sent by `user`.

  ## Examples

      iex> create_conversation_message(%Conversation{}, %User{}, %{field: value})
      {:ok, %Message{}}

      iex> create_conversation_message(%Conversation{}, %User{}, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_conversation_message(conversation, user, attrs \\ %{}) do
    message_changeset =
      conversation
      |> Ecto.build_assoc(:messages)
      |> Message.creation_changeset(attrs, user)

    conversation_changeset =
      Conversation.new_message_changeset(conversation)

    Multi.new()
    |> Multi.insert(:message, message_changeset)
    |> Multi.update(:conversation, conversation_changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} ->
        report_non_approved_message(message)
        {:ok, message}

      _error ->
        {:error, message_changeset}
    end
  end

  @doc """
  Approves the message named by the raw request `message_id`, on behalf of
  `actor`.

  The message is loaded with its conversation and authorized for `:approve`
  (moderators and admins): a non-castable id is `{:error, :not_found}`, and a
  well-formed id naming no row authorizes `nil`, which no moderator rule permits,
  so it is `{:error, :unauthorized}` (`{:error, :not_found}` for admins). On
  success the message is approved, both sides of the conversation are marked
  unread, its open reports are closed and reindexed, and a moderation log is
  written.

  Returns `{:ok, message}` on success.

  ## Examples

      iex> approve_message(%User{}, "1")
      {:ok, %Message{}}

  """
  @spec approve_message(User.t(), any()) ::
          {:ok, Message.t()} | {:error, :unauthorized | :not_found} | {:error, Ecto.Changeset.t()}
  def approve_message(actor, message_id) do
    case IntegerId.parse(message_id) do
      {:ok, id} ->
        message =
          Message
          |> preload(:conversation)
          |> Repo.get(id)

        with :ok <- authorize(actor, :approve, message),
             %Message{} <- message do
          approve_loaded_message(actor, message)
        else
          {:error, :unauthorized} -> {:error, :unauthorized}
          nil -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp approve_loaded_message(actor, message) do
    message_changeset = Message.approve_changeset(message)

    conversation_update_query =
      from c in Conversation,
        where: c.id == ^message.conversation_id,
        update: [set: [from_read: false, to_read: false]]

    reports_query =
      Reports.close_report_query({"Conversation", message.conversation_id}, actor)

    Multi.new()
    |> Multi.update(:message, message_changeset)
    |> Multi.update_all(:conversation, conversation_update_query, [])
    |> Multi.update_all(:reports, reports_query, [])
    |> Repo.transaction()
    |> case do
      {:ok, %{reports: {_count, reports}, message: message}} ->
        Reports.reindex_reports(reports)

        ModerationLogs.create_moderation_log(
          actor,
          "Conversation.Message.Approve:create",
          "/",
          "Approved private message in conversation ##{message.conversation_id}"
        )

        {:ok, message}

      _error ->
        {:error, message_changeset}
    end
  end

  @doc """
  Generates a system report for an unapproved message.

  This is called by `create_conversation_from/2` and `create_conversation_message/3`, so it
  normally does not need to be called explicitly.

  ## Examples

      iex> report_non_approved_message(%Message{approved: false})
      {:ok, %Report{}}

      iex> report_non_approved_message(%Message{approved: true})
      {:ok, nil}

  """
  def report_non_approved_message(message) do
    if message.approved do
      {:ok, nil}
    else
      Reports.create_system_report(
        {"Conversation", message.conversation_id},
        "Approval",
        "PM contains externally-embedded images"
      )
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking message changes.

  ## Examples

      iex> change_message(message)
      %Ecto.Changeset{source: %Message{}}

  """
  def change_message(%Message{} = message) do
    Message.changeset(message, %{})
  end
end
