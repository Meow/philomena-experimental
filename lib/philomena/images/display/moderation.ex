defmodule Philomena.Images.Display.Moderation do
  @moduledoc """
  Presentation data for an image's moderation controls.

  Contains affordances for miscellaneous image moderation tools,
  the hidden from users state, and the moderation scratchpad.
  """

  alias Philomena.Images.Display.Anonymous
  alias Philomena.Images.Display.CommentsLock
  alias Philomena.Images.Display.DescriptionLock
  alias Philomena.Images.Display.Feature
  alias Philomena.Images.Display.File
  alias Philomena.Images.Display.Hash
  alias Philomena.Images.Display.Hide
  alias Philomena.Images.Display.Repair
  alias Philomena.Images.Display.Scratchpad
  alias Philomena.Images.Display.SourceHistory
  alias Philomena.Images.Display.TagsLock
  alias Philomena.Images.Display.UploaderInput

  @enforce_keys [
    :hidden_from_users?,
    :scratchpad,
    :anonymous_changeset,
    :comments_lock_changeset,
    :description_lock_changeset,
    :feature_changeset,
    :file_changeset,
    :hash_changeset,
    :hide_changeset,
    :repair_changeset,
    :source_history_changeset,
    :tags_lock_changeset,
    :uploader_input_changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          hidden_from_users?: boolean(),
          scratchpad: Scratchpad.t() | nil,
          anonymous_changeset: Ecto.Changeset.t(Anonymous.t()) | nil,
          comments_lock_changeset: Ecto.Changeset.t(CommentsLock.t()) | nil,
          description_lock_changeset: Ecto.Changeset.t(DescriptionLock.t()) | nil,
          feature_changeset: Ecto.Changeset.t(Feature.t()) | nil,
          file_changeset: Ecto.Changeset.t(File.t()) | nil,
          hash_changeset: Ecto.Changeset.t(Hash.t()) | nil,
          hide_changeset: Ecto.Changeset.t(Hide.t()) | nil,
          repair_changeset: Ecto.Changeset.t(Repair.t()) | nil,
          source_history_changeset: Ecto.Changeset.t(SourceHistory.t()) | nil,
          tags_lock_changeset: Ecto.Changeset.t(TagsLock.t()) | nil,
          uploader_input_changeset: Ecto.Changeset.t(UploaderInput.t()) | nil
        }
end
