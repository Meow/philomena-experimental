defmodule Philomena.Images.Display.ModerationMetadata do
  @moduledoc """
  Presentation data for image moderation metadata.
  """

  @enforce_keys [:approved?, :hidden_from_users?, :duplicate_id, :deletion_reason, :deleter]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          approved?: boolean(),
          hidden_from_users?: boolean(),
          duplicate_id: integer() | nil,
          deletion_reason: String.t() | nil,
          # TODO(presentation-split)
          deleter: Philomena.Users.User.t() | nil
        }
end
