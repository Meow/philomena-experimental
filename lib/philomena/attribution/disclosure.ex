defmodule Philomena.Attribution.Disclosure do
  @moduledoc """
  Safe attribution data for a viewer.

  The underlying user, IP address, and fingerprint are optional by design. A
  caller should pass this projection to presentation code instead of passing
  an image's raw attribution fields and asking a template to hide them.
  """

  alias Philomena.Users.User

  @enforce_keys [:user, :anonymous, :ip, :fingerprint]
  defstruct [:user, :anonymous, :ip, :fingerprint]

  @type t :: %__MODULE__{
          user: User.t() | nil,
          anonymous: boolean(),
          ip: EctoNetwork.INET.t() | nil,
          fingerprint: String.t() | nil
        }
end
