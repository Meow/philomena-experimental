defmodule Philomena.ImageFaves do
  @moduledoc """
  Transaction steps for favorite rows owned by `Philomena.Images`.

  This module performs no authorization. Its functions require an
  already-loaded image and user after the owning context has enforced
  prerequisites.
  """

  import Ecto.Query, warn: false

  alias Philomena.Multi
  alias Philomena.ImageFaves.ImageFave
  alias Philomena.Images.Image
  alias Philomena.UserStatistics
  alias Philomena.Users.User

  defp delete_fave_steps(multi, image, user) do
    fave_query =
      ImageFave
      |> where(image_id: ^image.id)
      |> where(user_id: ^user.id)

    image_query = where(Image, id: ^image.id)

    multi
    |> Multi.delete_all(:unfave, fave_query)
    |> Multi.run(:dec_faves_count, fn repo, %{unfave: {faves, nil}} ->
      {count, nil} = repo.update_all(image_query, inc: [faves_count: -faves])
      {:ok, count}
    end)
    |> Multi.merge(fn %{unfave: {faves, nil}} ->
      UserStatistics.put_increment(Multi.new(), user, :image_faves_count, -faves)
    end)
  end

  @doc """
  Adds favorite steps for a loaded image and user to `multi`.

  The caller must have authorized the loaded image. The steps first remove any
  existing favorite, adjusting `faves_count` and the user's image-fave
  statistic by the number of rows removed, and then insert one row and add one
  to both counters. Repeated execution is therefore idempotent. The changes are
  named `:unfave`, `:dec_faves_count`, `:fave`, `:inc_faves_count`, and
  `:inc_fave_stat`.

  ## Examples

      iex> (Multi.new()
      ...> |> put_fave_for_loaded_image(image, user)
      ...> |> Multi.transact())
      {:ok, %{fave: %ImageFave{}}}

  """
  @spec put_fave_for_loaded_image(Multi.t(), Image.t(), User.t()) :: Multi.t()
  def put_fave_for_loaded_image(%Multi{} = multi, %Image{} = image, %User{} = user) do
    fave =
      %ImageFave{image_id: image.id, user_id: user.id}
      |> ImageFave.changeset(%{})

    image_query = where(Image, id: ^image.id)

    multi
    |> delete_fave_steps(image, user)
    |> Multi.insert(:fave, fave)
    |> Multi.update_all(:inc_faves_count, image_query, inc: [faves_count: 1])
    |> UserStatistics.put_increment(user, :image_faves_count, 1)
  end

  @doc """
  Adds favorite deletion steps for a loaded image and user to `multi`.

  The caller must have authorized the loaded image.`:dec_faves_count` adjusts
  the image and user counters by that exact number, so deleting an absent
  favorite changes nothing.

  ## Examples

      iex> (Multi.new()
      ...> |> delete_fave_for_loaded_image(image, user)
      ...> |> Multi.transact())
      {:ok, %{unfave: {0, nil}}}

  """
  @spec delete_fave_for_loaded_image(Multi.t(), Image.t(), User.t()) :: Multi.t()
  def delete_fave_for_loaded_image(%Multi{} = multi, %Image{} = image, %User{} = user) do
    delete_fave_steps(multi, image, user)
  end
end
