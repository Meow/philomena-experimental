defmodule Philomena.Profiles.ProfilePage do
  @moduledoc """
  Everything a user's public profile shows for one viewer: the user with its
  profile associations, the recent-uploads/faves/artwork image strips, the
  viewer's interactions across them, the recent comments and posts, recent
  galleries, the 90-day statistics series, watcher counts for the user's
  verified-link tags, the user's public-link tags, and the user's bans.

  Comments are carried twice: `recent_comments` is the unfiltered strip the
  view pairs rendered bodies against, and `authorized_comments` is the subset
  whose images the viewer may see, which the caller renders. Descriptions and
  commission text are carried raw on `user`; rendering them is the caller's
  concern.
  """

  alias Philomena.Users.User

  @enforce_keys [
    :user,
    :recent_uploads,
    :recent_faves,
    :recent_artwork,
    :recent_comments,
    :authorized_comments,
    :recent_posts,
    :recent_galleries,
    :statistics,
    :watcher_counts,
    :tags,
    :interactions,
    :bans
  ]
  defstruct [
    :user,
    :recent_uploads,
    :recent_faves,
    :recent_artwork,
    :recent_comments,
    :authorized_comments,
    :recent_posts,
    :recent_galleries,
    :statistics,
    :watcher_counts,
    :tags,
    :interactions,
    :bans
  ]

  @type t :: %__MODULE__{
          user: User.t(),
          recent_uploads: list(),
          recent_faves: list(),
          recent_artwork: list(),
          recent_comments: list(),
          authorized_comments: list(),
          recent_posts: list(),
          recent_galleries: list(),
          statistics: map(),
          watcher_counts: map(),
          tags: list(),
          interactions: list(),
          bans: list()
        }
end
