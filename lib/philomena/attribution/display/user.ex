defmodule Philomena.Attribution.Display.User do
  @moduledoc """
  Presentation data for a non-anonymously attributed user and award list.
  """

  alias Philomena.Users.Display.User
  alias Philomena.Badges.Display.Award
  alias Philomena.Badges.Display.Badge

  @enforce_keys [:user, :awards]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          user: User.t(),
          awards: [Award.t()]
        }

  @doc false
  def render(%Philomena.Users.User{} = user) do
    %__MODULE__{
      user: User.render(user),
      awards:
        Enum.map(user.awards, fn award ->
          badge = Badge.render(award.badge)
          Award.render(award, badge)
        end)
    }
  end
end
