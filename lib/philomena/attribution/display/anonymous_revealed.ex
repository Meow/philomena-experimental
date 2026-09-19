defmodule Philomena.Attribution.Display.AnonymousRevealed do
  @moduledoc """
  Presentation data for an anonymously attributed user who is revealed to staff.
  """

  alias Philomena.Users

  @enforce_keys [:discriminant, :user]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          discriminant: String.t(),
          user: Users.Display.User.t()
        }

  @doc false
  def render(%Users.User{} = user, discriminant) do
    %__MODULE__{
      user: Users.Display.User.render(user),
      discriminant: discriminant
    }
  end
end
