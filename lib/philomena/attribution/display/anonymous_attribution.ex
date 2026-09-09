defmodule Philomena.Attribution.Display.AnonymousAttribution do
  @moduledoc """
  Presentation data for an anonymously attributed user.
  """

  @enforce_keys [:discriminant]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          discriminant: String.t()
        }
end
