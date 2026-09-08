defmodule Philomena.Images.Display.Sources do
  @moduledoc """
  Presentation data for an image's sources area.
  """

  alias Philomena.Images.Display.SourceInput
  alias Philomena.Images.Display.Source
  alias Philomena.Images.Image

  @enforce_keys [
    :source_change_count,
    :sources,
    :changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_change_count: non_neg_integer(),
          sources: [Source.t()],
          changeset: Ecto.Changeset.t(SourceInput.t()) | nil
        }

  @doc false
  def render(
        %Image{sources: sources},
        source_change_count,
        source_input_changeset
      ) do
    %__MODULE__{
      source_change_count: source_change_count,
      sources: Enum.map(sources, &Source.render/1),
      changeset: source_input_changeset
    }
  end
end
