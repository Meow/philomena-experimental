defmodule Philomena.Attribution.Display.IdentityMetadata do
  @moduledoc """
  Presentation data for IP/fingerprint attribution pairs.
  """

  import Philomena.Authorization, only: [permitted?: 3]

  alias Philomena.Attribution.Actor

  @enforce_keys [:ip, :fingerprint]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          ip: Postgrex.INET.t(),
          fingerprint: String.t()
        }

  @spec display_identity_metadata(Actor.t(), struct()) :: t() | nil
  def display_identity_metadata(%Actor{} = actor, object) do
    if permitted?(actor, :show, :identity_metadata) do
      %__MODULE__{
        ip: object.ip,
        fingerprint: object.fingerprint
      }
    end
  end
end
