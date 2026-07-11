defmodule PhilomenaWeb.IntegerId do
  @moduledoc """
  Deprecated home of `Philomena.IntegerId`.

  Id parsing moved into the domain layer so that contexts, which cannot
  reference `PhilomenaWeb`, can turn raw request ids into an ordinary
  "no such row" themselves. This module remains only so web-layer call sites
  keep compiling until each is migrated; it is deleted once they are gone.
  """

  defdelegate parse(id), to: Philomena.IntegerId
end
