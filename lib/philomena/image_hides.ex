defmodule Philomena.ImageHides do
  @moduledoc """
  Transaction steps for hide rows owned by `Philomena.Images`.

  This module performs no authorization. Its functions require an
  already-loaded image and user after the owning context has enforced
  prerequisites.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Philomena.ImageHides.ImageHide
  alias Philomena.Images.Image
  alias Philomena.Users.User

  defp delete_hide_steps(multi, image, user) do
    hide_query =
      ImageHide
      |> where(image_id: ^image.id)
      |> where(user_id: ^user.id)

    image_query = where(Image, id: ^image.id)

    multi
    |> Multi.delete_all(:unhide, hide_query)
    |> Multi.run(:dec_hides_count, fn repo, %{unhide: {hides, nil}} ->
      {count, nil} = repo.update_all(image_query, inc: [hides_count: -hides])
      {:ok, count}
    end)
  end

  @doc """
  Adds hide steps for a loaded image and user to `multi`.

  The caller must have authorized the loaded image. The steps first remove any
  existing favorite, adjusting `hides_count` by the number of rows removed, and
  then insert one row and add one to both counters. Repeated execution is
  therefore idempotent. The changes are named `:unhide`, `:dec_hides_count`,
  `:hide`, and `:inc_hides_count`

  ## Examples

      iex> (Multi.new()
      ...> |> put_hide_for_loaded_image(image, user)
      ...> |> Repo.transaction())
      {:ok, %{hide: %ImageHide{}}}

  """
  @spec put_hide_for_loaded_image(Multi.t(), Image.t(), User.t()) :: Multi.t()
  def put_hide_for_loaded_image(%Multi{} = multi, %Image{} = image, %User{} = user) do
    hide =
      %ImageHide{image_id: image.id, user_id: user.id}
      |> ImageHide.changeset(%{})

    image_query = where(Image, id: ^image.id)

    multi
    |> delete_hide_steps(image, user)
    |> Multi.insert(:hide, hide)
    |> Multi.update_all(:inc_hides_count, image_query, inc: [hides_count: 1])
  end

  @doc """
  Adds hide deletion steps for a loaded image and user to `multi`.

  The caller must have authorized the loaded image. `:dec_hides_count` adjusts
  the image counter by that exact number, so deleting an absent hide changes
  nothing.

  ## Examples

      iex> (Multi.new()
      ...> |> delete_hide_for_loaded_image(image, user)
      ...> |> Repo.transaction())
      {:ok, %{unhide: {0, nil}}}

  """
  @spec delete_hide_for_loaded_image(Multi.t(), Image.t(), User.t()) :: Multi.t()
  def delete_hide_for_loaded_image(%Multi{} = multi, %Image{} = image, %User{} = user) do
    delete_hide_steps(multi, image, user)
  end
end
