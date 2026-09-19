defmodule Philomena.Images.Display.Moderation do
  @moduledoc """
  Presentation data for an image's moderation controls.

  Contains affordances for miscellaneous image moderation tools,
  the hidden from users state, and the moderation scratchpad.
  """

  alias Philomena.Images.Forms.Anonymous
  alias Philomena.Images.Forms.Approval
  alias Philomena.Images.Forms.CommentsLock
  alias Philomena.Images.Forms.DescriptionLock
  alias Philomena.Images.Forms.Destruction
  alias Philomena.Images.Forms.Feature
  alias Philomena.Images.Forms.File
  alias Philomena.Images.Forms.Hash
  alias Philomena.Images.Forms.Hide
  alias Philomena.Images.Forms.LockedTags
  alias Philomena.Images.Forms.Repair
  alias Philomena.Images.Forms.Scratchpad
  alias Philomena.Images.Forms.SourceHistory
  alias Philomena.Images.Forms.TagsLock
  alias Philomena.Images.Forms.UploaderInput

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
          anonymous_changeset: Ecto.Changeset.t(Anonymous.t()) | nil,
          approval_changeset: Ecto.Changeset.t(Approval.t()) | nil,
          comments_lock_changeset: Ecto.Changeset.t(CommentsLock.t()) | nil,
          description_lock_changeset: Ecto.Changeset.t(DescriptionLock.t()) | nil,
          destruction_changeset: Ecto.Changeset.t(Destruction.t()) | nil,
          feature_changeset: Ecto.Changeset.t(Feature.t()) | nil,
          file_changeset: Ecto.Changeset.t(File.t()) | nil,
          hash_changeset: Ecto.Changeset.t(Hash.t()) | nil,
          hide_changeset: Ecto.Changeset.t(Hide.t()) | nil,
          locked_tags_changeset: Ecto.Changeset.t(LockedTags.t()) | nil,
          repair_changeset: Ecto.Changeset.t(Repair.t()) | nil,
          scratchpad_changeset: Ecto.Changeset.t(Scratchpad.t()) | nil,
          source_history_changeset: Ecto.Changeset.t(SourceHistory.t()) | nil,
          tags_lock_changeset: Ecto.Changeset.t(TagsLock.t()) | nil,
          uploader_input_changeset: Ecto.Changeset.t(UploaderInput.t()) | nil
        }
end
