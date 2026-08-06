defmodule Philomena.Commissions.ItemForm do
  @moduledoc """
  A profile and commission, new or existing item, and the
  changeset rendered by commission item forms.
  """

  alias Philomena.Commissions.Commission
  alias Philomena.Commissions.Item
  alias Philomena.Users.User

  @enforce_keys [:user, :commission, :item, :changeset]
  defstruct [:user, :commission, :item, :changeset]

  @type t :: %__MODULE__{
          user: User.t(),
          commission: Commission.t(),
          item: Item.t(),
          changeset: Ecto.Changeset.t()
        }
end
