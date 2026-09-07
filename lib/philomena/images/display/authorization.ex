defmodule Philomena.Images.Display.Authorization do
  @moduledoc false

  import Philomena.Authorization, only: [permitted?: 3, write_access?: 1]

  alias Philomena.Attribution.Actor
  alias Philomena.Images.Image
  alias Philomena.Images

  @doc """
  Returns whether `actor` may perform an image `action` for a display control.

  The actor must have write access, be permitted to perform `action` on
  `image`, and not be prevented from viewing the image by a forced filter.

  ## Examples

      iex> image_permitted?(moderator_actor, :approve, image)
      true

      iex> image_permitted?(user_actor, :approve, image)
      false

  """
  @spec image_permitted?(Actor.t(), atom(), Image.t()) :: boolean()
  def image_permitted?(%Actor{} = actor, action, %Image{} = image) do
    write_access?(actor) and permitted?(actor, action, image) and
      not Images.force_filtered?(actor, image)
  end
end
