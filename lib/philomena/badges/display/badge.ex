defmodule Philomena.Badges.Display.Badge do
  @moduledoc """
  Presentation data for a badge.
  """

  alias Philomena.Badges.Badge

  @enforce_keys [:title, :uri, :priority, :id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          title: String.t(),
          uri: String.t(),
          priority: boolean(),
          id: integer()
        }

  @doc false
  def render(%Badge{} = badge) do
    %__MODULE__{
      title: badge.title,
      uri: "#{badge_url_root()}/#{badge.image}",
      priority: badge.priority,
      id: badge.id
    }
  end

  defp badge_url_root do
    Application.get_env(:philomena, :badge_url_root)
  end
end
