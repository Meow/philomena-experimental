defmodule Philomena.Comments.Display.Moderation do
  @moduledoc """
  Presentation data for comment controls.
  """

  @enforce_keys [
    :report_changeset,
    :reply_changeset,
    :edit_changeset,
    :approve_changeset,
    :destroy_changeset,
    :hide_changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          # TODO(presentation-split)
          report_changeset: Ecto.Changeset.t(Philomena.Reports.Report.t()) | nil,
          # TODO(presentation-split)
          reply_changeset: Ecto.Changeset.t(Philomena.Comments.Comment.t()) | nil,
          edit_changeset: Ecto.Changeset.t(Philomena.Comments.Comment.t()) | nil,
          approve_changeset: Ecto.Changeset.t(Philomena.Comments.Comment.t()) | nil,
          destroy_changeset: Ecto.Changeset.t(Philomena.Comments.Comment.t()) | nil,
          hide_changeset: Ecto.Changeset.t(Philomena.Comments.Comment.t()) | nil
        }
end
