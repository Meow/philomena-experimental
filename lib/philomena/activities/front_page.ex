defmodule Philomena.Activities.FrontPage do
  @moduledoc """
  The assembled homepage: the recent-image listing, the top-scoring strip, the
  recent-comment strip, the viewer's watched images (`nil` for anonymous
  visitors), the current featured image, the live-stream and forum-topic
  strips. Each image preview carries the viewer's interaction state.
  """

  alias Philomena.Channels.Channel
  alias Philomena.Comments.Comment
  alias Philomena.Images
  alias Philomena.Topics.Topic

  @enforce_keys [
    :images,
    :top_scoring,
    :comments,
    :watched,
    :featured_image,
    :streams,
    :topics
  ]
  defstruct images: nil,
            top_scoring: nil,
            comments: nil,
            watched: nil,
            featured_image: nil,
            streams: [],
            topics: []

  @type t :: %__MODULE__{
          images: Scrivener.Page.t(Images.Display.Preview.t()),
          top_scoring: Scrivener.Page.t(Images.Display.Preview.t()),
          comments: Scrivener.Page.t(Comment.t()),
          watched: Scrivener.Page.t(Images.Display.Preview.t()) | nil,
          featured_image: Images.Display.Preview.t() | nil,
          streams: [Channel.t()],
          topics: [Topic.t()]
        }
end
