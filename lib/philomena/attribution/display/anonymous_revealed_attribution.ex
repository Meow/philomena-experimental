defmodule Philomena.Attribution.Display.AnonymousRevealedAttribution do
  @moduledoc """
  Presentation data for an anonymously attributed user who is revealed to staff.
  """

  @enforce_keys [:discriminant, :user]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          discriminant: String.t(),
          # TODO(presentation-split)
          user: Philomena.Users.User.t()
        }
end
