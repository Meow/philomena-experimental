defmodule Philomena.Images.Display.ModerationMetadata do
  @moduledoc """
  Presentation data for image moderation metadata.
  """

  alias Philomena.Images.Image
  alias Philomena.Users.Display.User

  @enforce_keys [
    :approved?,
    :hidden_from_users?,
    :destroyed?,
    :duplicate_id,
    :deletion_reason,
    :deleter
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          approved?: boolean(),
          hidden_from_users?: boolean(),
          destroyed?: boolean(),
          duplicate_id: integer() | nil,
          deletion_reason: String.t() | nil,
          # TODO(presentation-split): not present vs not disclosed?
          deleter: User.t() | nil
        }

  @doc false
  def render(%Image{} = image, may_reveal_deleter?) do
    %__MODULE__{
      approved?: image.approved,
      hidden_from_users?: image.hidden_from_users,
      destroyed?: image.destroyed_content,
      duplicate_id: image.duplicate_id,
      deletion_reason: image.deletion_reason,
      deleter:
        if may_reveal_deleter? and not is_nil(image.deleter) do
          User.render(image.deleter)
        end
    }
  end
end
