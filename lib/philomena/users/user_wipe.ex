defmodule Philomena.Users.UserWipe do
  @moduledoc """
  Performs the asynchronous personally identifying information cleanup owned by
  the Users context.

  The public entry point accepts only a trusted persisted user ID and is called
  by `Philomena.UserWipeWorker` after an authorized Users service enqueues it.
  """

  import Ecto.Query

  alias Philomena.Comments.Comment
  alias Philomena.Images.Image
  alias Philomena.Posts.Post
  alias Philomena.Reports.Report
  alias Philomena.SourceChanges.SourceChange
  alias Philomena.TagChanges.TagChange
  alias Philomena.UserIps.UserIp
  alias Philomena.UserFingerprints.UserFingerprint
  alias Philomena.Users
  alias Philomena.Users.User
  alias Philomena.Repo
  alias PhilomenaQuery.Batch

  @wipe_ip %Postgrex.INET{address: {127, 0, 1, 1}, netmask: 32}
  @wipe_fp "ffff"

  @doc """
  Replaces a user's stored IPs, fingerprints, and email with erased values.

  A missing ID is an invariant violation and raises. Attribution-bearing rows
  are updated in batches and the user search document is reindexed afterward.

  ## Examples

      iex> UserWipe.perform(user.id)
      %User{}
  """
  @spec perform(integer()) :: User.t()
  def perform(user_id) do
    user = Users.fetch_user_for_worker!(user_id)

    random_hex = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    for schema <- [Comment, Image, Post, Report, SourceChange, TagChange] do
      schema
      |> where(user_id: ^user.id)
      |> Batch.query_batches()
      |> Enum.each(&Repo.update_all(&1, set: [ip: @wipe_ip, fingerprint: @wipe_fp]))
    end

    UserIp
    |> where(user_id: ^user.id)
    |> Repo.delete_all()

    UserFingerprint
    |> where(user_id: ^user.id)
    |> Repo.delete_all()

    User
    |> where(id: ^user.id)
    |> Repo.update_all(set: [email: "deactivated#{random_hex}@example.com"])

    Users.reindex_user(user)
  end
end
