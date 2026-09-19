defmodule Philomena.Attribution.Display.Attribution do
  @moduledoc """
  Presentation data for user attribution.
  """

  alias Philomena.Attribution.Display

  @type t ::
          {:anonymous, Display.Anonymous.t()}
          | {:anonymous_revealed, Display.AnonymousRevealed.t()}
          | {:user, Display.User.t()}
end
