defmodule Philomena.Tags.Display.Tag do
  @moduledoc """
  Presentation data for a tag in a tag list.
  """

  alias Philomena.Tags.Tag

  @derive {Phoenix.Param, key: :slug}

  @enforce_keys [
    :id,
    :slug,
    :name,
    :category,
    :short_description,
    :images_count
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: integer(),
          slug: String.t(),
          name: String.t(),
          category: String.t() | nil,
          short_description: String.t() | nil,
          images_count: non_neg_integer()
        }

  @doc false
  def render(%Tag{} = tag) do
    %__MODULE__{
      id: tag.id,
      slug: tag.slug,
      name: tag.name,
      category: tag.category,
      short_description: tag.short_description,
      images_count: tag.images_count
    }
  end
end
