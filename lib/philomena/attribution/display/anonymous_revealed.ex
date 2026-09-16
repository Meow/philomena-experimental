defmodule Philomena.Attribution.Display.AnonymousRevealed do
  @moduledoc """
  Presentation data for an anonymously attributed user who is revealed to staff.
  """

  alias Philomena.Users.Display.User

  @enforce_keys [:discriminant, :user]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          discriminant: String.t(),
          user: User.t()
        }

  @doc false
  def render(%Philomena.Users.User{} = user, discriminant) do
    %__MODULE__{
      user: User.render(user),
      discriminant: discriminant
    }
  end
end
