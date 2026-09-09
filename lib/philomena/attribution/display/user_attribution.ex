defmodule Philomena.Attribution.Display.UserAttribution do
  @moduledoc """
  Presentation data for a non-anonymously attributed user and award list.
  """

  @enforce_keys [:user, :awards]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          # TODO(presentation-split)
          user: Philomena.Users.User.t(),
          awards: [Philomena.Badges.Award.t()]
        }
end
