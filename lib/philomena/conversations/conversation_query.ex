defmodule Philomena.Conversations.ConversationQuery do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @int_max 2_147_483_647

  embedded_schema do
    field :partner_id, :integer
  end

  @doc false
  def changeset(query, params) do
    attrs =
      case params do
        %{} -> %{"partner_id" => Map.get(params, "with")}
        _ -> %{}
      end

    query
    |> cast(attrs, [:partner_id])
    |> validate_number(:partner_id, greater_than: 0, less_than_or_equal_to: @int_max)
  end
end
