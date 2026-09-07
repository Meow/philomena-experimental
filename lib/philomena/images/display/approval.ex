defmodule Philomena.Images.Display.Approval do
  @moduledoc """
  Presentation data for an image approval control.

  Contains a changeset and the image's current `approved?` state.

  Omitted when the control is unavailable to the actor.
  """

  import Philomena.Images.Display.Authorization

  alias Philomena.Attribution.Actor
  alias Philomena.Images.Image
  alias Philomena.Forms

  defmodule Form do
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

  @enforce_keys [:changeset, :approved?]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          changeset: Ecto.Changeset.t(Form.t()),
          approved?: boolean()
        }

  @doc false
  @spec render(Actor.t(), Image.t()) :: t() | nil
  def render(%Actor{} = actor, %Image{} = image) do
    if image_permitted?(actor, :approve, image) do
      %__MODULE__{
        changeset: Forms.change(Form, %{}),
        approved?: image.approved
      }
    end
  end
end
