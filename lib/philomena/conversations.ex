defmodule Philomena.Conversations do
  @moduledoc """
  Actor-scoped conversation listing, creation, reading, replies, and message
  approval.

  Conversation slugs load before authorization, nested message IDs are scoped
  to their route conversation, and missing resources have actor-independent
  not-found results. Database writes complete before report indexing and rate
  limiter side effects run. Conversation and message writes do not emit email
  or notification events; the header count reads the persisted participant
  flags directly.
  """

  import Ecto.Query, warn: false
  import Philomena.Authorization, only: [authorize: 3, verify_write_access: 1]

  alias Ecto.Multi
  alias Philomena.Attribution.Actor
  alias Philomena.Conversations.Conversation
  alias Philomena.Conversations.ConversationForm
  alias Philomena.Conversations.ConversationIndex
  alias Philomena.Conversations.ConversationPage
  alias Philomena.Conversations.ConversationQuery
  alias Philomena.Conversations.Message
  alias Philomena.Conversations.MessageCreated
  alias Philomena.Conversations.MessageForm
  alias Philomena.IntegerId
  alias Philomena.Loader
  alias Philomena.ModerationLogs
  alias Philomena.RateLimiter
  alias Philomena.Repo
  alias Philomena.Reports
  alias Philomena.Users
  alias Philomena.Users.User

  @conversation_create_window 60

  defp normalize_params(%{} = params), do: params
  defp normalize_params(_params), do: %{}

  defp normalized_recipient(params) do
    case Map.get(params, "recipient") do
      recipient when is_binary(recipient) -> recipient
      _recipient -> nil
    end
  end

  defp new_conversation(recipient) do
    %Conversation{recipient: recipient, messages: [%Message{}]}
  end

  defp change_conversation(%Conversation{} = conversation) do
    Conversation.changeset(conversation, %{})
  end

  defp conversation_form(%Conversation{} = conversation, %Ecto.Changeset{} = changeset) do
    %ConversationForm{conversation: conversation, changeset: changeset}
  end

  defp conversation_form(%Conversation{} = conversation) do
    conversation_form(conversation, change_conversation(conversation))
  end

  defp recipient_for_creation(actor, recipient) do
    case Users.load_active_user_by_name(actor, recipient) do
      {:ok, user} -> user
      {:error, _reason} -> nil
    end
  end

  defp insert_conversation(actor, attrs) do
    attrs = normalize_params(attrs)
    recipient = normalized_recipient(attrs)
    conversation = %Conversation{recipient: recipient}
    to = recipient_for_creation(actor, recipient)
    changeset = Conversation.creation_changeset(conversation, actor.user, to, attrs)

    case Repo.insert(changeset) do
      {:ok, conversation} ->
        conversation.messages
        |> List.first()
        |> report_non_approved_message()

        {:ok, conversation}

      {:error, changeset} ->
        {:error, conversation_form(conversation, changeset)}
    end
  end

  defp compile_index_query(params) do
    changeset = ConversationQuery.changeset(%ConversationQuery{}, params)

    case Ecto.Changeset.apply_action(changeset, :index) do
      {:ok, query} -> {:ok, {query, changeset}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp conversation_index_query(%User{id: user_id}, partner_id) do
    Conversation
    |> where(
      [conversation],
      (conversation.from_id == ^user_id and not conversation.from_hidden) or
        (conversation.to_id == ^user_id and not conversation.to_hidden)
    )
    |> maybe_filter_partner(user_id, partner_id)
    |> then(fn query ->
      from conversation in query,
        as: :conversation,
        inner_lateral_join:
          count in subquery(
            from message in Message,
              where: message.conversation_id == parent_as(:conversation).id,
              select: %{value: count()}
          ),
        on: true,
        order_by: [desc: conversation.last_message_at, desc: conversation.id],
        preload: [:to, :from],
        select: %{conversation | message_count: count.value}
    end)
  end

  defp maybe_filter_partner(query, _user_id, nil), do: query

  defp maybe_filter_partner(query, user_id, partner_id) do
    where(
      query,
      [conversation],
      (conversation.from_id == ^partner_id and conversation.to_id == ^user_id) or
        (conversation.to_id == ^partner_id and conversation.from_id == ^user_id)
    )
  end

  defp empty_page(pagination) do
    %Scrivener.Page{
      entries: [],
      page_number:
        pagination_value(
          pagination,
          :page,
          pagination_value(pagination, :page_number, 1)
        ),
      page_size: pagination_value(pagination, :page_size, 25),
      total_entries: 0,
      total_pages: 1
    }
  end

  defp pagination_value(pagination, key, default) when is_map(pagination) do
    Map.get(pagination, key, default)
  end

  defp pagination_value(pagination, key, default) do
    Keyword.get(pagination, key, default)
  end

  defp load_conversation(actor, slug, action, preloads \\ []) do
    Conversation
    |> where(slug: ^slug)
    |> preload(^preloads)
    |> Loader.one_and_authorize(actor, action)
  end

  defp participant?(%Conversation{} = conversation, %User{id: user_id}) do
    conversation.from_id == user_id or conversation.to_id == user_id
  end

  defp participant?(%Conversation{}, nil), do: false

  defp update_read_state(%Conversation{} = conversation, %User{} = user, read) do
    changes =
      %{}
      |> put_conditional(:to_read, read, conversation.to_id == user.id)
      |> put_conditional(:from_read, read, conversation.from_id == user.id)

    conversation
    |> Conversation.read_changeset(changes)
    |> Repo.update()
  end

  defp update_hidden_state(%Conversation{} = conversation, %User{} = user, hidden) do
    changes =
      %{}
      |> put_conditional(:to_hidden, hidden, conversation.to_id == user.id)
      |> put_conditional(:from_hidden, hidden, conversation.from_id == user.id)

    conversation
    |> Conversation.hidden_changeset(changes)
    |> Repo.update()
  end

  defp put_conditional(map, key, value, true), do: Map.put(map, key, value)
  defp put_conditional(map, _key, _value, false), do: map

  defp unread_count(%User{id: user_id}) do
    Conversation
    |> where(
      [conversation],
      ((conversation.to_id == ^user_id and not conversation.to_read) or
         (conversation.from_id == ^user_id and not conversation.from_read)) and
        not ((conversation.to_id == ^user_id and conversation.to_hidden) or
               (conversation.from_id == ^user_id and conversation.from_hidden))
    )
    |> Repo.aggregate(:count)
  end

  defp change_message(%Message{} = message) do
    Message.changeset(message, %{})
  end

  defp paginate_messages(conversation, user, pagination) do
    direction = if user.settings.messages_newest_first, do: :desc, else: :asc

    Message
    |> where(conversation_id: ^conversation.id)
    |> order_by([{^direction, :created_at}, {^direction, :id}])
    |> preload(:from)
    |> Repo.paginate(pagination)
  end

  defp message_count_query(%Conversation{id: conversation_id}) do
    from message in Message,
      where: message.conversation_id == ^conversation_id,
      select: count(message.id)
  end

  defp new_message(%Conversation{} = conversation) do
    Ecto.build_assoc(conversation, :messages)
  end

  defp insert_message(%Conversation{} = conversation, %User{} = user, attrs) do
    message = new_message(conversation)
    message_changeset = Message.creation_changeset(message, normalize_params(attrs), user)
    conversation_changeset = Conversation.new_message_changeset(conversation)

    Multi.new()
    |> Multi.insert(:message, message_changeset)
    |> Multi.update(:conversation, conversation_changeset)
    |> Multi.one(:message_count, message_count_query(conversation))
    |> Repo.transaction()
    |> case do
      {:ok, %{conversation: conversation, message: message, message_count: message_count}} ->
        report_non_approved_message(message)

        {:ok,
         %MessageCreated{
           conversation: conversation,
           message: message,
           message_count: message_count
         }}

      {:error, :message, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, %MessageForm{conversation: conversation, message: message, changeset: changeset}}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp item_for_approval(actor, conversation, message_id) do
    Message
    |> where(conversation_id: ^conversation.id)
    |> preload(:conversation)
    |> Loader.fetch_and_authorize(actor, :approve, message_id)
  end

  defp approve_loaded_message(actor, message) do
    conversation_update_query =
      from conversation in Conversation,
        where: conversation.id == ^message.conversation_id,
        update: [set: [from_read: false, to_read: false]]

    log_body = "Approved private message in conversation ##{message.conversation_id}"

    Multi.new()
    |> Multi.update(:message, Message.approve_changeset(message))
    |> Multi.update_all(:conversation, conversation_update_query, [])
    |> Reports.put_close_reports(
      :reports,
      actor.user,
      conversation_id: message.conversation_id
    )
    |> ModerationLogs.put_log(
      :moderation_log,
      actor,
      "Conversation.Message.Approve:create",
      "/",
      log_body
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{reports: {_count, report_ids}, message: message}} ->
        Reports.reindex_closed_reports(report_ids)
        {:ok, message}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  defp report_non_approved_message(nil), do: {:ok, nil}
  defp report_non_approved_message(%Message{approved: true}), do: {:ok, nil}

  defp report_non_approved_message(%Message{} = message) do
    Reports.create_system_report(
      "Approval",
      "PM contains externally-embedded images",
      conversation_id: message.conversation_id
    )
  end

  @doc """
  Loads the signed-in actor's paginated conversation index.

  The optional `"with"` filter is parsed as a positive user ID before query
  compilation. Invalid or out-of-range filters return an empty page and an
  invalid changeset rather than raising a cast/encoding error.

  ## Examples

      iex> load_conversation_index(actor, %{}, page: 1, page_size: 25)
      {:ok, %ConversationIndex{}}

  """
  @spec load_conversation_index(Actor.t(), term(), Repo.pagination_params()) ::
          {:ok, ConversationIndex.t()} | {:error, :unauthorized}
  def load_conversation_index(%Actor{user: user} = actor, params, pagination) do
    with :ok <- authorize(actor, :index, Conversation) do
      case compile_index_query(params) do
        {:ok, {query, changeset}} ->
          conversations =
            user
            |> conversation_index_query(query.partner_id)
            |> Repo.paginate(pagination)

          {:ok, %ConversationIndex{conversations: conversations, changeset: changeset}}

        {:error, changeset} ->
          {:ok,
           %ConversationIndex{
             conversations: empty_page(pagination),
             changeset: changeset
           }}
      end
    end
  end

  @doc """
  Returns the authenticated actor's unread, non-hidden conversation count.

  This is the narrow notification-header service; raw count queries remain
  private to Conversations.

  ## Examples

      iex> unread_conversation_count(actor)
      {:ok, 3}

  """
  @spec unread_conversation_count(Actor.t()) ::
          {:ok, non_neg_integer()} | {:error, :unauthorized}
  def unread_conversation_count(%Actor{user: user} = actor) do
    with :ok <- authorize(actor, :index, Conversation) do
      {:ok, unread_count(user)}
    end
  end

  @doc """
  Loads one visible conversation page for `actor`.

  Missing slugs are not found for every actor. Participants and authorized
  staff may view the page. A participant's own read flag is set idempotently;
  staff viewing a conversation do not mutate either participant's state.

  ## Examples

      iex> load_conversation_page(actor, "slug", page_size: 25)
      {:ok, %ConversationPage{}}

  """
  @spec load_conversation_page(Actor.t(), String.t(), Repo.pagination_params()) ::
          {:ok, ConversationPage.t()} | {:error, :unauthorized | :not_found}
  def load_conversation_page(%Actor{user: user} = actor, slug, pagination) do
    with {:ok, conversation} <- load_conversation(actor, slug, :show, [:to, :from]) do
      messages = paginate_messages(conversation, user, pagination)

      if participant?(conversation, user) do
        {:ok, _conversation} = update_read_state(conversation, user, true)
      end

      {:ok,
       %ConversationPage{
         conversation: conversation,
         messages: messages,
         changeset: change_message(%Message{})
       }}
    end
  end

  @doc """
  Loads a visible conversation as a report target.

  This shares the canonical load-before-authorize slug contract used by the
  conversation page.
  """
  @spec load_report_target(Actor.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, :unauthorized | :not_found}
  def load_report_target(%Actor{} = actor, slug) do
    load_conversation(actor, slug, :show, [:from, :to])
  end

  @doc """
  Builds a new-conversation form for `actor`.

  New and create apply the same write-access and class-ability prerequisites.
  Non-string recipient input is normalized to an empty recipient.

  ## Examples

      iex> new_conversation(actor, "Recipient")
      {:ok, %ConversationForm{}}

  """
  @spec new_conversation(Actor.t(), term()) ::
          {:ok, ConversationForm.t()} | {:error, :ban | :unauthorized}
  def new_conversation(%Actor{} = actor, recipient) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :new, Conversation) do
      recipient = if is_binary(recipient), do: recipient, else: nil
      {:ok, recipient |> new_conversation() |> conversation_form()}
    end
  end

  @doc """
  Creates a conversation and its single initial message for `actor`.

  Params of any shape are normalized before changeset construction. Active
  recipients resolve through Users; missing or deactivated recipients produce
  a `ConversationForm` validation error. Successful writes are rate-counted
  after commit, and an unapproved first message creates its system report after
  the conversation transaction succeeds.

  ## Examples

      iex> create_conversation(actor, attrs)
      {:ok, %Conversation{}}

      iex> create_conversation(actor, invalid_attrs)
      {:error, %ConversationForm{}}

  """
  @spec create_conversation(Actor.t(), term()) ::
          {:ok, Conversation.t()}
          | {:error, ConversationForm.t()}
          | {:error, :ban | :unauthorized | :rate_limited}
  def create_conversation(%Actor{} = actor, params) do
    with :ok <- verify_write_access(actor),
         :ok <- authorize(actor, :create, Conversation),
         :ok <- RateLimiter.check_rate_limit(actor, :conversation_create),
         {:ok, conversation} <- insert_conversation(actor, params) do
      RateLimiter.record_action(actor, :conversation_create, @conversation_create_window)
      {:ok, conversation}
    end
  end

  @doc """
  Marks `actor`'s participant side of the conversation read or unread.

  The operation is idempotent. Authorized staff may view the conversation but,
  because they are not a participant, do not change either participant flag.
  Missing slugs are always not found.
  """
  @spec set_conversation_read(Actor.t(), String.t(), boolean()) ::
          {:ok, Conversation.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def set_conversation_read(%Actor{user: user} = actor, slug, read \\ true) do
    with {:ok, conversation} <- load_conversation(actor, slug, :show) do
      if participant?(conversation, user) do
        update_read_state(conversation, user, read)
      else
        {:ok, conversation}
      end
    end
  end

  @doc """
  Marks `actor`'s participant side of the conversation hidden or restored.

  The operation is idempotent, authorized staff viewing as nonparticipants
  change neither participant flag, and missing slugs are always not found.
  """
  @spec set_conversation_hidden(Actor.t(), String.t(), boolean()) ::
          {:ok, Conversation.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def set_conversation_hidden(%Actor{user: user} = actor, slug, hidden \\ true) do
    with {:ok, conversation} <- load_conversation(actor, slug, :show) do
      if participant?(conversation, user) do
        update_hidden_state(conversation, user, hidden)
      else
        {:ok, conversation}
      end
    end
  end

  @doc """
  Posts a reply to a visible conversation.

  Write access is checked before loading. Participant and staff reply policy is
  represented by the `:reply` ability. Validation failures return a
  `MessageForm` containing the actual rejected changeset; success returns the
  message and total count needed for the redirect page.

  ## Examples

      iex> create_message(actor, "slug", %{"body" => "hello"})
      {:ok, %MessageCreated{}}

      iex> create_message(actor, "slug", %{"body" => ""})
      {:error, %MessageForm{}}

  """
  @spec create_message(Actor.t(), String.t(), term()) ::
          {:ok, MessageCreated.t()}
          | {:error, MessageForm.t()}
          | {:error, :ban | :unauthorized | :not_found | Ecto.Changeset.t()}
  def create_message(%Actor{user: user} = actor, slug, params) do
    with :ok <- verify_write_access(actor),
         {:ok, conversation} <- load_conversation(actor, slug, :reply) do
      insert_message(conversation, user, params)
    end
  end

  @doc """
  Approves one message scoped to the conversation named by `conversation_slug`.

  The route conversation loads before the nested message query. Malformed,
  absent, and wrong-conversation message IDs are therefore all not found.
  Approval, participant unread flags, report closure, and the moderation log
  commit atomically; affected report documents are reindexed after commit.

  ## Examples

      iex> approve_message(actor, "conversation-slug", "1")
      {:ok, %Message{}}

  """
  @spec approve_message(Actor.t(), String.t(), IntegerId.integer_id()) ::
          {:ok, Message.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def approve_message(%Actor{} = actor, conversation_slug, message_id) do
    with {:ok, conversation} <- load_conversation(actor, conversation_slug, :show),
         {:ok, message} <- item_for_approval(actor, conversation, message_id) do
      approve_loaded_message(actor, message)
    end
  end
end
