defmodule Philomena.Images.Display.Moderation do
  @moduledoc """
  Presentation data for an image's moderation controls.

  Contains affordances for miscellaneous image moderation tools,
  the hidden from users state, and the moderation scratchpad.
  """

  alias Philomena.Images.Forms

  @enforce_keys [
    :hidden_from_users?,
    :anonymous_changeset,
    :approval_changeset,
    :comments_lock_changeset,
    :description_lock_changeset,
    :destruction_changeset,
    :feature_changeset,
    :file_changeset,
    :hash_changeset,
    :hide_changeset,
    :locked_tags_changeset,
    :repair_changeset,
    :scratchpad_changeset,
    :source_history_changeset,
    :tags_lock_changeset,
    :uploader_input_changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hidden_from_users?: boolean(),
          anonymous_changeset: Ecto.Changeset.t(Forms.Anonymous.t()) | nil,
          approval_changeset: Ecto.Changeset.t(Forms.Approval.t()) | nil,
          comments_lock_changeset: Ecto.Changeset.t(Forms.CommentsLock.t()) | nil,
          description_lock_changeset: Ecto.Changeset.t(Forms.DescriptionLock.t()) | nil,
          destruction_changeset: Ecto.Changeset.t(Forms.Destruction.t()) | nil,
          feature_changeset: Ecto.Changeset.t(Forms.Feature.t()) | nil,
          file_changeset: Ecto.Changeset.t(Forms.File.t()) | nil,
          hash_changeset: Ecto.Changeset.t(Forms.Hash.t()) | nil,
          hide_changeset: Ecto.Changeset.t(Forms.Hide.t()) | nil,
          locked_tags_changeset: Ecto.Changeset.t(Forms.LockedTags.t()) | nil,
          repair_changeset: Ecto.Changeset.t(Forms.Repair.t()) | nil,
          scratchpad_changeset: Ecto.Changeset.t(Forms.Scratchpad.t()) | nil,
          source_history_changeset: Ecto.Changeset.t(Forms.SourceHistory.t()) | nil,
          tags_lock_changeset: Ecto.Changeset.t(Forms.TagsLock.t()) | nil,
          uploader_input_changeset: Ecto.Changeset.t(Forms.UploaderInput.t()) | nil
        }
end
