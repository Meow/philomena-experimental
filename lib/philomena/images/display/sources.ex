defmodule Philomena.Images.Display.Sources do
  @moduledoc """
  Presentation data for an image's sources area.
  """

  alias Philomena.Images.Display.Source
  alias Philomena.Images.Display.SourceInput
  alias Philomena.Images.Image

  @enforce_keys [
    :source_changes_count,
    :sources,
    :changeset
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_changes_count: non_neg_integer(),
          sources: [Source.t()],
          changeset: Ecto.Changeset.t(SourceInput.t()) | nil
        }

  @doc false
  def render(%Image{sources: sources}, source_changes_count, source_input_changeset) do
    %__MODULE__{
      source_changes_count: source_changes_count,
      sources: Enum.map(sources, &Source.render/1),
      changeset: source_input_changeset
    }
  end
end
