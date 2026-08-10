defmodule Philomena.ImageVotes do
  @moduledoc """
  Transaction steps for the vote rows owned by `Philomena.Images`.

  This module is not an authorization or input-validation boundary. Its
  functions require an already-loaded image and user plus a validated boolean
  direction after the owning context has enforced request prerequisites.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Philomena.Images.Image
  alias Philomena.ImageVotes.ImageVote
  alias Philomena.UserStatistics
  alias Philomena.Users.User

  defp delete_vote_steps(multi, image, user) do
    user_vote_query =
      ImageVote
      |> where(image_id: ^image.id)
      |> where(user_id: ^user.id)

    image_query = where(Image, id: ^image.id)

    multi
    |> Multi.delete_all(:unupvote, where(user_vote_query, up: true))
    |> Multi.delete_all(:undownvote, where(user_vote_query, up: false))
    |> Multi.run(:dec_votes_count, fn repo,
                                      %{unupvote: {upvotes, nil}, undownvote: {downvotes, nil}} ->
      {count, nil} =
        repo.update_all(image_query,
          inc: [
            upvotes_count: -upvotes,
            downvotes_count: -downvotes,
            score: downvotes - upvotes
          ]
        )

      with {:ok, _statistic} <-
             UserStatistics.increment(user, :image_votes_count, -(upvotes + downvotes)) do
        {:ok, count}
      end
    end)
  end

  @doc """
  Adds replacement-vote steps for a loaded image and user to `multi`.

  The caller must have authorized the image and validated `up`. Any existing
  direction is removed before the requested direction is inserted, with score,
  image direction counters, and the user's vote statistic adjusted by the
  actual row deltas. Repeated votes and direction changes are idempotent. The
  changes are named `:unupvote`, `:undownvote`, `:dec_votes_count`, `:vote`,
  `:inc_vote_count`, and `:inc_vote_stat`; a uniqueness conflict rolls the
  surrounding transaction back.

  ## Examples

      iex> Multi.new() |> put_vote_for_loaded_image(image, user, true) |> Repo.transaction()
      {:ok, %{vote: %ImageVote{up: true}}}

  """
  @spec put_vote_for_loaded_image(Multi.t(), Image.t(), User.t(), boolean()) :: Multi.t()
  def put_vote_for_loaded_image(%Multi{} = multi, %Image{} = image, %User{} = user, up)
      when is_boolean(up) do
    vote =
      %ImageVote{image_id: image.id, user_id: user.id, up: up}
      |> ImageVote.changeset(%{})

    image_query = where(Image, id: ^image.id)
    upvotes = if up, do: 1, else: 0
    downvotes = if up, do: 0, else: 1

    multi
    |> delete_vote_steps(image, user)
    |> Multi.insert(:vote, vote)
    |> Multi.update_all(:inc_vote_count, image_query,
      inc: [upvotes_count: upvotes, downvotes_count: downvotes, score: upvotes - downvotes]
    )
    |> Multi.run(:inc_vote_stat, fn _repo, _changes ->
      UserStatistics.increment(user, :image_votes_count, 1)
    end)
  end

  @doc """
  Adds idempotent vote-deletion steps for a loaded image and user to `multi`.

  The caller must have authorized the loaded image. The two delete changes
  report the removed direction, and `:dec_votes_count` adjusts score, image
  counters, and the user statistic by those exact deltas. Deleting an absent
  vote changes nothing.

  ## Examples

      iex> Multi.new() |> delete_vote_for_loaded_image(image, user) |> Repo.transaction()
      {:ok, %{unupvote: {0, nil}, undownvote: {0, nil}}}

  """
  @spec delete_vote_for_loaded_image(Multi.t(), Image.t(), User.t()) :: Multi.t()
  def delete_vote_for_loaded_image(%Multi{} = multi, %Image{} = image, %User{} = user) do
    delete_vote_steps(multi, image, user)
  end
end
