defmodule Philomena.Comments.Display.Comment do
  @moduledoc """
  Presentation data for an image comment.
  """

  alias Philomena.Attribution
  alias Philomena.Attribution
  alias Philomena.Comments.Comment
  alias Philomena.Comments.Display
  alias Philomena.Users

  @derive {Phoenix.Param, key: :id}

  @enforce_keys [
    :id,
    :image_id,
    :created_at,
    :author,
    :identity_metadata,
    :moderation_metadata,
    :options,
    :body
  ]
  defstruct @enforce_keys

  @type communication_body :: %{
          body: String.t(),
          edit_reason: String.t() | nil,
          edited_at: DateTime.t() | nil
        }

  @type communication_redaction :: %{
          deletion_reason: String.t() | nil,
          # TODO(presentation-split): not present vs not disclosed?
          deleted_by: Users.Display.User.t() | nil
        }

  # TODO(presentation-split): redundancy with moderation metadata
  @type body ::
          {:visible, communication_body()}
          | {:withheld, communication_body() | nil}
          | {:redacted, communication_redaction(), communication_body() | nil}
          | {:destroyed, communication_redaction()}

  @type moderation_metadata :: %{
          approved?: boolean(),
          hidden_from_users?: boolean(),
          destroyed?: boolean(),
          deletion_reason: String.t() | nil,
          # TODO(presentation-split): not present vs not disclosed?
          deleted_by: Users.Display.User.t() | nil
        }

  @type t :: %__MODULE__{
          id: integer(),
          image_id: integer(),
          created_at: DateTime.t(),
          author: Attribution.Display.Attribution.t(),
          identity_metadata: Attribution.Display.IdentityMetadata.t() | nil,
          moderation_metadata: moderation_metadata(),
          options: Display.Options.t(),
          body: body()
        }

  @doc false
  def render(
        %Comment{} = comment,
        author,
        identity_metadata,
        options,
        may_reveal_unapproved?,
        may_reveal_redacted?
      ) do
    body =
      cond do
        comment.destroyed_content ->
          {:destroyed, render_redaction(comment, may_reveal_redacted?)}

        comment.hidden_from_users ->
          {:redacted, render_redaction(comment, may_reveal_redacted?),
           if(may_reveal_redacted?, do: render_body(comment))}

        not comment.approved ->
          {:withheld, if(may_reveal_unapproved?, do: render_body(comment))}

        true ->
          {:visible, render_body(comment)}
      end

    %__MODULE__{
      id: comment.id,
      image_id: comment.image_id,
      created_at: comment.created_at,
      author: author,
      identity_metadata: identity_metadata,
      moderation_metadata: %{
        approved?: comment.approved,
        hidden_from_users: comment.hidden_from_users,
        destroyed?: comment.destroyed_content
      },
      options: options,
      body: body
    }
  end

  defp render_body(%Comment{} = comment) do
    %{
      body: comment.body,
      edit_reason: comment.edit_reason,
      edited_at: comment.edited_at
    }
  end

  defp render_redaction(%Comment{} = comment, may_reveal_redacted?) do
    %{
      deletion_reason: comment.deletion_reason,
      deleted_by:
        if may_reveal_redacted? and not is_nil(comment.deleted_by) do
          Users.Display.User.render(comment.deleted_by)
        end
    }
  end
end
