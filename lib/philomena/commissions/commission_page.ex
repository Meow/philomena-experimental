defmodule Philomena.Commissions.CommissionPage do
  @moduledoc """
  A visible profile and commission listing, with listing items ordered by
  base price and ID.
  """

  alias Philomena.Commissions.Commission
  alias Philomena.Users.User

  @enforce_keys [:user, :commission]
  defstruct [:user, :commission]

  @type t :: %__MODULE__{user: User.t(), commission: Commission.t()}
end
