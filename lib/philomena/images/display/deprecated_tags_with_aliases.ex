defmodule Philomena.Images.Display.DeprecatedTagsWithAliases do
  @moduledoc """
  Presentation data for an image's tags container data.
  """

  alias Philomena.Tags.Display.Tag
  alias Philomena.Images.Image

  @enforce_keys [:tags_with_aliases]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          tags_with_aliases: [Tag.t()]
        }

  @doc false
  def render(%Image{tags: tags}) do
    %__MODULE__{
      tags_with_aliases:
        tags
        |> Enum.flat_map(&([&1] ++ &1.aliases))
        |> Enum.map(&Tag.render/1)
    }
  end
end
