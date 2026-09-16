defmodule Philomena.Badges.Display.Award do
  @moduledoc """
  Presentation data for a badge award.
  """

  alias Philomena.Badges.Display.Badge
  alias Philomena.Badges.Award

  @enforce_keys [:title, :label, :created_at, :id, :badge]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          title: String.t(),
          label: String.t(),
          created_at: DateTime.t(),
          id: integer(),
          badge: Badge.t()
        }

  @doc false
  def render(%Award{} = award, %Badge{} = badge) do
    %__MODULE__{
      title: presence(award.badge_name) || badge.title,
      label: award.label,
      badge: badge,
      created_at: award.awarded_on,
      id: award.id
    }
  end

  defp presence(string) do
    string != "" && string
  end
end
