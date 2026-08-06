defmodule Philomena.Reports.ReportForm do
  @moduledoc """
  A report form paired with the safely loaded target it reports.

  The target is retained when validation fails so the controller can render the
  same form without loading or authorizing the resource a second time.
  """

  alias Philomena.Comments.Comment
  alias Philomena.Commissions.Commission
  alias Philomena.Conversations.Conversation
  alias Philomena.Galleries.Gallery
  alias Philomena.Images.Image
  alias Philomena.Posts.Post
  alias Philomena.Users.User

  @type target ::
          Image.t()
          | Comment.t()
          | Post.t()
          | User.t()
          | Commission.t()
          | Conversation.t()
          | Gallery.t()

  @enforce_keys [:target, :changeset]
  defstruct [:target, :changeset]

  @type t :: %__MODULE__{target: target(), changeset: Ecto.Changeset.t()}
end
