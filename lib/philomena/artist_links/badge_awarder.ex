defmodule Philomena.ArtistLinks.BadgeAwarder do
  @moduledoc """
  Performs artist badge awarding for verified artist links.
  """

  alias Philomena.Badges.{Award, Badge}
  alias Philomena.Repo

  @badge_title "Artist"

  @doc """
  Awards a badge to an artist with a verified link.

  If the badge with the title `"Artist"` does not exist, no award will be created.
  If the user already has an award with that badge title, no award will be created.

  Returns `{:ok, award}`, `{:ok, nil}`, or `{:error, changeset}`. The return value is
  suitable for use as the return value to an `Ecto.Multi.run/3` callback.
  """
  def award_badge(artist_link, verifying_user) do
    with %Badge{} = badge <- Repo.get_by(Badge, title: @badge_title),
         nil <- Repo.get_by(Award, badge_id: badge.id, user_id: artist_link.user.id) do
      %Award{awarded_by_id: verifying_user.id, user_id: artist_link.user.id}
      |> Award.changeset(%{badge_id: badge.id})
      |> Repo.insert()
    else
      _ ->
        {:ok, nil}
    end
  end
end
