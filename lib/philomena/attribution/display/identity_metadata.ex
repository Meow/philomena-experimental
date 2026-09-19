defmodule Philomena.Attribution.Display.IdentityMetadata do
  @moduledoc """
  Presentation data for IP/fingerprint attribution pairs.
  """

  @enforce_keys [:ip, :fingerprint]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ip: Postgrex.INET.t(),
          fingerprint: String.t()
        }

  def render(object) do
    %__MODULE__{
      ip: object.ip,
      fingerprint: object.fingerprint
    }
  end
end
