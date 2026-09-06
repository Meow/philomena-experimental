defmodule Philomena.Images.Display.ApprovalForm do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  embedded_schema do
  end

  @doc false
  def changeset(approval_form, attrs \\ %{}) do
    cast(approval_form, attrs, [])
  end
end
