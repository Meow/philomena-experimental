defmodule Philomena.Profiles.Display.Award do
  @moduledoc """
  Presentation data for a profile badge award row.
  """

  alias Philomena.Badges.Display.Award
  alias Philomena.Users.Display.User

  @enforce_keys [:award, :awarded_by, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          award: Award.t(),
          awarded_by: User.t() | nil,
          changeset: Ecto.Changeset.t() | nil
        }

  @doc false
  def render(%Award{} = award, awarded_by, changeset) do
    %__MODULE__{
      award: award,
      awarded_by: awarded_by,
      changeset: changeset
    }
  end
end
