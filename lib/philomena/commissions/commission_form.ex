defmodule Philomena.Commissions.CommissionForm do
  @moduledoc """
  A loaded profile, new or existing commission, and the changeset
  rendered by commission new/edit forms.
  """

  alias Philomena.Commissions.Commission
  alias Philomena.Users.User

  @enforce_keys [:user, :commission, :changeset]
  defstruct [:user, :commission, :changeset]

  @type t :: %__MODULE__{
          user: User.t(),
          commission: Commission.t(),
          changeset: Ecto.Changeset.t()
        }
end
