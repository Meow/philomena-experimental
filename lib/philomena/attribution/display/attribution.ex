defmodule Philomena.Attribution.Display.Attribution do
  @moduledoc """
  Presentation data for user attribution.
  """

  alias Philomena.Attribution.Display.{
    AnonymousAttribution,
    AnonymousRevealedAttribution,
    UserAttribution
  }

  @type t ::
          {:anonymous, AnonymousAttribution.t()}
          | {:anonymous_revealed, AnonymousRevealedAttribution.t()}
          | {:user, UserAttribution.t()}
end
