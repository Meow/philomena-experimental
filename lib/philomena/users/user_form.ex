defmodule Philomena.Users.UserForm do
  @moduledoc """
  A loaded user and the changeset rendered by a self-service or profile form.

  The same shape is returned for the initial form and validation failures.
  """

  alias Philomena.Users.User

  @enforce_keys [:user, :changeset]
  defstruct [:user, :changeset]

  @type t :: %__MODULE__{user: User.t(), changeset: Ecto.Changeset.t()}
end
