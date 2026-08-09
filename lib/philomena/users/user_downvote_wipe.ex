defmodule Philomena.Users.UserDownvoteWipe do
  @moduledoc """
  Performs the asynchronous vote/favorite cleanup owned by the Users context.

  The public entry point accepts only a trusted persisted user ID and is called
  by `Philomena.UserUnvoteWorker` after an authorized Users service enqueues it.
  """

  import Ecto.Query

  alias PhilomenaQuery.Batch
  alias PhilomenaQuery.Search
  alias Philomena.Users
  alias Philomena.Users.User
  alias Philomena.Images.Image
  alias Philomena.Images
  alias Philomena.ImageVotes.ImageVote
  alias Philomena.ImageFaves.ImageFave
  alias Philomena.Repo

  defp reindex(image_ids) do
    Image
    |> where([i], i.id in ^image_ids)
    |> preload(^Images.indexing_preloads())
    |> Search.reindex(Image)

    # Allow time for indexing to catch up before the next destructive batch.
    :timer.sleep(:timer.seconds(10))
  end

  @doc """
  Removes a user's downvotes and, when requested, their upvotes and favorites.

  A missing ID is an invariant violation and raises. Affected image and user
  counters are updated in batches, and affected images are reindexed after each
  batch.

  ## Examples

      iex> UserDownvoteWipe.perform(user.id)
      :ok

      iex> UserDownvoteWipe.perform(user.id, true)
      :ok
  """
  @spec perform(integer(), boolean()) :: :ok
  def perform(user_id, upvotes_and_faves_too \\ false) do
    user = Users.fetch_user_for_worker!(user_id)

    ImageVote
    |> where(user_id: ^user.id, up: false)
    |> Batch.query_batches(id_field: :image_id)
    |> Enum.each(fn queryable ->
      {_, image_ids} = Repo.delete_all(select(queryable, [i_v], i_v.image_id))

      {count, nil} =
        Repo.update_all(where(Image, [i], i.id in ^image_ids),
          inc: [downvotes_count: -1, score: 1]
        )

      Repo.update_all(where(User, id: ^user.id), inc: [image_votes_count: -count])

      reindex(image_ids)
    end)

    if upvotes_and_faves_too do
      ImageVote
      |> where(user_id: ^user.id, up: true)
      |> Batch.query_batches(id_field: :image_id)
      |> Enum.each(fn queryable ->
        {_, image_ids} = Repo.delete_all(select(queryable, [i_v], i_v.image_id))

        {count, nil} =
          Repo.update_all(where(Image, [i], i.id in ^image_ids),
            inc: [upvotes_count: -1, score: -1]
          )

        Repo.update_all(where(User, id: ^user.id), inc: [image_votes_count: -count])

        reindex(image_ids)
      end)

      ImageFave
      |> where(user_id: ^user.id)
      |> Batch.query_batches(id_field: :image_id)
      |> Enum.each(fn queryable ->
        {_, image_ids} = Repo.delete_all(select(queryable, [i_f], i_f.image_id))

        {count, nil} =
          Repo.update_all(where(Image, [i], i.id in ^image_ids), inc: [faves_count: -1])

        Repo.update_all(where(User, id: ^user.id), inc: [image_faves_count: -count])

        reindex(image_ids)
      end)
    end

    :ok
  end
end
