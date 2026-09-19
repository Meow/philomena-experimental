defmodule Philomena.Images.Display.Subscription do
  @moduledoc """
  Presentation data for an image's subscription.
  """

  alias Philomena.Images.Forms

  @enforce_keys [:subscribed?, :changeset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          subscribed?: boolean(),
          changeset: Ecto.Changeset.t(Forms.SubscriptionInteraction.t()) | nil
        }

  @doc false
  def render(subscribed?, changeset) do
    %__MODULE__{subscribed?: subscribed?, changeset: changeset}
  end
end
