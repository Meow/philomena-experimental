defmodule Philomena.Attribution.Display.Attribution do
  @moduledoc """
  Presentation data for user attribution.
  """

  alias Philomena.Attribution.Display.{
    Anonymous,
    AnonymousRevealed,
    User
  }

  @type t ::
          {:anonymous, Anonymous.t()}
          | {:anonymous_revealed, AnonymousRevealed.t()}
          | {:user, User.t()}
end
