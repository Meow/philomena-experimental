defmodule Philomena.Users.AdminUserForm do
  @moduledoc """
  A staff-managed user, its edit changeset, and the assignable roles.
  """

  alias Philomena.Roles.Role
  alias Philomena.Users.User

  @enforce_keys [:user, :changeset, :roles]
  defstruct [:user, :changeset, :roles]

  @type t :: %__MODULE__{
          user: User.t(),
          changeset: Ecto.Changeset.t(),
          roles: [Role.t()]
        }
end
