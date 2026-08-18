defmodule Philomena.Interactions do
  @moduledoc """
  Image interaction loads and transaction steps used by authorized image merges.
  """

  import Ecto.Query

  alias Philomena.Multi
  alias Philomena.Attribution.Actor
  alias Philomena.ImageFaves.ImageFave
  alias Philomena.ImageHides.ImageHide
  alias Philomena.Images.Image
  alias Philomena.ImageVotes.ImageVote
  alias Philomena.Repo
  alias Philomena.UserStatistics

  @type interaction :: %{
          image_id: pos_integer(),
          user_id: pos_integer(),
          interaction_type: String.t(),
          value: String.t()
        }

  defp flatten_images(nil), do: []
  defp flatten_images(id) when is_integer(id), do: [id]
  defp flatten_images(%{id: id}), do: [id]
  defp flatten_images({%{id: id}, _hit}), do: [id]
  defp flatten_images(enum), do: Enum.flat_map(enum, &flatten_images/1)

  defp interaction_ids(images) do
    images
    |> flatten_images()
    |> Enum.uniq()
  end

  defp interactions_for_user([], _user), do: []

  defp interactions_for_user(ids, user) do
    hide_interactions =
      ImageHide
      |> select([h], %{
        image_id: h.image_id,
        user_id: h.user_id,
        interaction_type: ^"hidden",
        value: ^""
      })
      |> where([h], h.image_id in ^ids)
      |> where(user_id: ^user.id)

    fave_interactions =
      ImageFave
      |> select([f], %{
        image_id: f.image_id,
        user_id: f.user_id,
        interaction_type: ^"faved",
        value: ^""
      })
      |> where([f], f.image_id in ^ids)
      |> where(user_id: ^user.id)

    upvote_interactions =
      ImageVote
      |> select([v], %{
        image_id: v.image_id,
        user_id: v.user_id,
        interaction_type: ^"voted",
        value: ^"up"
      })
      |> where([v], v.image_id in ^ids)
      |> where(user_id: ^user.id, up: true)

    downvote_interactions =
      ImageVote
      |> select([v], %{
        image_id: v.image_id,
        user_id: v.user_id,
        interaction_type: ^"voted",
        value: ^"down"
      })
      |> where([v], v.image_id in ^ids)
      |> where(user_id: ^user.id, up: false)

    [hide_interactions, fave_interactions, upvote_interactions, downvote_interactions]
    |> Enum.reduce(&union_all(&2, ^&1))
    |> Repo.all()
  end

  defp source_interactions(repo, source) do
    source = repo.preload(source, [:hiders, :favers, :upvoters, :downvoters], force: true)
    {:ok, %{source: source, created_at: DateTime.utc_now(:second)}}
  end

  defp hide_rows(%{source: source, created_at: created_at}, target) do
    Enum.map(source.hiders, &%{image_id: target.id, user_id: &1.id, created_at: created_at})
  end

  defp fave_rows(%{source: source, created_at: created_at}, target) do
    Enum.map(source.favers, &%{image_id: target.id, user_id: &1.id, created_at: created_at})
  end

  defp vote_rows(%{source: source, created_at: created_at}, target, up) do
    voters = if up, do: source.upvoters, else: source.downvoters

    Enum.map(voters, &%{image_id: target.id, user_id: &1.id, created_at: created_at, up: up})
  end

  @doc """
  Lists `actor`'s interactions with all supplied images.

  `images` may be a page or another enumerable containing loaded images,
  integer IDs, `{image, hit}` search results, nested lists, duplicates,
  and `nil`. Duplicates and `nil` are ignored. Anonymous actors return `[]`
  without querying. The result omits images with no interaction and uses
  specific strings: `"hidden"`, `"faved"`, or `"voted"`, with
  values `"up"`/`"down"` only given for votes.

  ## Examples

      iex> user_interactions(actor, [image, {other_image, hit}])
      [%{image_id: 42, user_id: 7, interaction_type: "voted", value: "up"}]

      iex> user_interactions(anonymous_actor, [image])
      []

  """
  @spec user_interactions(Actor.t(), Enumerable.t()) :: [interaction()]
  def user_interactions(%Actor{user: nil}, _images), do: []

  def user_interactions(%Actor{user: user}, images) do
    images
    |> interaction_ids()
    |> interactions_for_user(user)
  end

  @doc """
  Adds interaction migration steps for loaded source and target images.

  The caller must authorize the merge in `Philomena.Images` and execute the
  returned `Ecto.Multi`. Hides, faves, and votes absent from the target are
  copied. When both images have the same user's interaction, the target row
  wins. Target counters, score, and user fave/vote statistics increase only for
  rows actually inserted. Source rows are unchanged.

  The added changes are named `:interaction_source`, `:interaction_hides`,
  `:interaction_faves`, `:interaction_upvotes`, `:interaction_downvotes`, and
  `:interaction_image`, keeping all copies and counter changes in the owner's
  transaction. The fave and vote changes retain the inserted rows so their
  user statistics can be incremented in bulk.

  ## Examples

      iex> (Multi.new()
      ...> |> migrate_loaded_images(source, target)
      ...> |> Multi.transact())
      {:ok, %{interaction_image: 1}}

  """
  @spec migrate_loaded_images(Multi.t(), Image.t(), Image.t()) :: Multi.t()
  def migrate_loaded_images(%Multi{} = multi, %Image{} = source, %Image{} = target) do
    multi
    |> Multi.run(:interaction_source, fn repo, _changes -> source_interactions(repo, source) end)
    |> Multi.run(:interaction_hides, fn repo, %{interaction_source: interactions} ->
      {count, nil} =
        repo.insert_all(ImageHide, hide_rows(interactions, target), on_conflict: :nothing)

      {:ok, count}
    end)
    |> Multi.run(:interaction_faves, fn repo, %{interaction_source: interactions} ->
      {count, rows} =
        repo.insert_all(ImageFave, fave_rows(interactions, target),
          on_conflict: :nothing,
          returning: [:user_id]
        )

      {:ok, {count, rows}}
    end)
    |> Multi.merge(fn %{interaction_faves: {_count, rows}} ->
      UserStatistics.put_bulk_increment(
        Multi.new(),
        Enum.map(rows, & &1.user_id),
        :image_faves_count
      )
    end)
    |> Multi.run(:interaction_upvotes, fn repo, %{interaction_source: interactions} ->
      {count, rows} =
        repo.insert_all(ImageVote, vote_rows(interactions, target, true),
          on_conflict: :nothing,
          returning: [:user_id]
        )

      {:ok, {count, rows}}
    end)
    |> Multi.merge(fn %{interaction_upvotes: {_count, rows}} ->
      UserStatistics.put_bulk_increment(
        Multi.new(),
        Enum.map(rows, & &1.user_id),
        :image_votes_count
      )
    end)
    |> Multi.run(:interaction_downvotes, fn repo, %{interaction_source: interactions} ->
      {count, rows} =
        repo.insert_all(ImageVote, vote_rows(interactions, target, false),
          on_conflict: :nothing,
          returning: [:user_id]
        )

      {:ok, {count, rows}}
    end)
    |> Multi.merge(fn %{interaction_downvotes: {_count, rows}} ->
      UserStatistics.put_bulk_increment(
        Multi.new(),
        Enum.map(rows, & &1.user_id),
        :image_votes_count
      )
    end)
    |> Multi.run(:interaction_image, fn repo,
                                        %{
                                          interaction_hides: hides,
                                          interaction_faves: {faves, _},
                                          interaction_upvotes: {upvotes, _},
                                          interaction_downvotes: {downvotes, _}
                                        } ->
      {count, nil} =
        repo.update_all(where(Image, id: ^target.id),
          inc: [
            hides_count: hides,
            faves_count: faves,
            upvotes_count: upvotes,
            downvotes_count: downvotes,
            score: upvotes - downvotes
          ]
        )

      {:ok, count}
    end)
  end
end
