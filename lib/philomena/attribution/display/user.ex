defmodule Philomena.Attribution.Display.User do
  @moduledoc """
  Presentation data for a non-anonymously attributed user and award list.
  """

  alias Philomena.Badges
  alias Philomena.Users

  @enforce_keys [:user, :awards]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          user: Users.Display.User.t(),
          awards: [Badges.Display.Award.t()]
        }

  @doc false
  def render(%Users.User{} = user) do
    %__MODULE__{
      user: Users.Display.User.render(user),
      awards:
        Enum.map(user.awards, fn award ->
          badge = Badges.Display.Badge.render(award.badge)
          Badges.Display.Award.render(award, badge)
        end)
    }
  end
end
